#if RACCOON_HAS_PLUGINS && defined(__APPLE__)
// The macOS half of plugins.h: plugin frameworks on FlutterMacOS's own
// channel and codec classes, over a messenger, registrar and texture
// registry of the runner's. Only the protocols are compiled here; the
// framework is opened at run time, before the plugins that link it.
#include "plugins.h"

#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
// The registrar header brings the protocols without FlutterEngine, a name
// the embedder API has too.
#import <FlutterMacOS/FlutterPluginRegistrarMacOS.h>
#import <Metal/Metal.h>
#include <dlfcn.h>

#include <unistd.h>

#include <cstdio>
#include <cstring>
#include <mutex>
#include <unordered_map>

using raccoon::PluginHost;

// ---- The messenger ----------------------------------------------------------

// A serial queue a handler asked to be called on.
@interface RaccoonTaskQueue : NSObject <FlutterTaskQueue>
@property(nonatomic, readonly) dispatch_queue_t queue;
@end

@implementation RaccoonTaskQueue
- (instancetype)init {
  if ((self = [super init])) {
    _queue = dispatch_queue_create("dev.raccoon.plugin", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}
@end

@interface RaccoonHandler : NSObject
@property(nonatomic) FlutterBinaryMessengerConnection connection;
@property(nonatomic, copy) FlutterBinaryMessageHandler handler;
@property(nonatomic, nullable) RaccoonTaskQueue* queue;
@end

@implementation RaccoonHandler
@end

@interface RaccoonMessenger : NSObject <FlutterBinaryMessenger>
- (instancetype)initWithBridge:(PluginHost::Bridge*)bridge;
// A message from the app; YES when a handler took it.
- (BOOL)handleMessage:(NSString*)channel
                 data:(NSData*)data
               handle:(const FlutterPlatformMessageResponseHandle*)handle;
@end

@implementation RaccoonMessenger {
  PluginHost::Bridge* _bridge;
  NSMutableDictionary<NSString*, RaccoonHandler*>* _handlers;
  FlutterBinaryMessengerConnection _nextConnection;
}

- (instancetype)initWithBridge:(PluginHost::Bridge*)bridge {
  if ((self = [super init])) {
    _bridge = bridge;
    _handlers = [NSMutableDictionary dictionary];
    _nextConnection = 1;
  }
  return self;
}

- (void)sendOnChannel:(NSString*)channel message:(NSData*)message {
  [self sendOnChannel:channel message:message binaryReply:nil];
}

- (void)sendOnChannel:(NSString*)channel
              message:(NSData*)message
          binaryReply:(FlutterBinaryReply)callback {
  // Channels belong to the platform thread; a plugin calling from another
  // gets there by the main queue.
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self sendOnChannel:channel message:message binaryReply:callback];
    });
    return;
  }
  std::function<void(const uint8_t*, size_t)> on_reply;
  if (callback != nil) {
    on_reply = [callback](const uint8_t* data, size_t size) {
      callback(data == nullptr ? nil : [NSData dataWithBytes:data length:size]);
    };
  }
  _bridge->send(channel.UTF8String, static_cast<const uint8_t*>(message.bytes), message.length,
                std::move(on_reply));
}

- (FlutterBinaryMessengerConnection)setMessageHandlerOnChannel:(NSString*)channel
                                          binaryMessageHandler:
                                              (FlutterBinaryMessageHandler)handler {
  return [self setMessageHandlerOnChannel:channel binaryMessageHandler:handler taskQueue:nil];
}

- (FlutterBinaryMessengerConnection)setMessageHandlerOnChannel:(NSString*)channel
                                          binaryMessageHandler:
                                              (FlutterBinaryMessageHandler)handler
                                                     taskQueue:
                                                         (NSObject<FlutterTaskQueue>*)taskQueue {
  if (handler == nil) {
    [_handlers removeObjectForKey:channel];
    return 0;
  }
  RaccoonHandler* entry = [[RaccoonHandler alloc] init];
  entry.connection = _nextConnection++;
  entry.handler = handler;
  if ([taskQueue isKindOfClass:[RaccoonTaskQueue class]]) {
    entry.queue = (RaccoonTaskQueue*)taskQueue;
  }
  _handlers[channel] = entry;
  return entry.connection;
}

- (NSObject<FlutterTaskQueue>*)makeBackgroundTaskQueue {
  return [[RaccoonTaskQueue alloc] init];
}

- (void)cleanUpConnection:(FlutterBinaryMessengerConnection)connection {
  NSString* found = nil;
  for (NSString* channel in _handlers) {
    if (_handlers[channel].connection == connection) found = channel;
  }
  if (found != nil) [_handlers removeObjectForKey:found];
}

- (BOOL)handleMessage:(NSString*)channel
                 data:(NSData*)data
               handle:(const FlutterPlatformMessageResponseHandle*)handle {
  RaccoonHandler* entry = _handlers[channel];
  if (entry == nil) return NO;
  PluginHost::Bridge* bridge = _bridge;
  // The engine's handle takes one answer; a second would be a use after
  // free on its side.
  __block BOOL answered = NO;
  FlutterBinaryReply reply = ^(NSData* answer) {
    if (handle == nullptr || answered) return;
    answered = YES;
    bridge->respond(handle, static_cast<const uint8_t*>(answer.bytes), answer.length);
  };
  FlutterBinaryMessageHandler handler = entry.handler;
  // A plugin that throws answers "not handled" and the runner goes on: one
  // plugin's exception is not every app's crash.
  void (^call)(void) = ^{
    @try {
      handler(data, reply);
    } @catch (NSException* exception) {
      std::fprintf(stderr, "🦝 %s threw %s: %s\n", channel.UTF8String,
                   exception.name.UTF8String, exception.reason.UTF8String);
      reply(nil);
    }
  };
  if (entry.queue != nil) {
    dispatch_async(entry.queue.queue, call);
  } else {
    call();
  }
  return YES;
}

@end

// ---- Textures ---------------------------------------------------------------

namespace {

// The Metal textures of a plugin texture's latest frame, kept until the
// next one: the engine draws them in between.
struct TextureFrame {
  CVMetalTextureRef planes[2] = {nullptr, nullptr};
  FlutterMetalTextureHandle handles[2] = {nullptr, nullptr};

  void Clear() {
    for (auto& plane : planes) {
      if (plane != nullptr) CFRelease(plane);
      plane = nullptr;
    }
  }
};

}  // namespace

@interface RaccoonTextures : NSObject <FlutterTextureRegistry>
- (instancetype)initWithBridge:(PluginHost::Bridge*)bridge;
- (BOOL)populate:(int64_t)textureId out:(FlutterMetalExternalTexture*)out;
@end

@implementation RaccoonTextures {
  PluginHost::Bridge* _bridge;
  CVMetalTextureCacheRef _cache;
  std::mutex _mutex;
  // Registered on the main thread, read on the raster thread.
  NSMutableDictionary<NSNumber*, NSObject<FlutterTexture>*>* _textures;
  std::unordered_map<int64_t, TextureFrame> _frames;
  int64_t _nextId;
}

- (instancetype)initWithBridge:(PluginHost::Bridge*)bridge {
  if ((self = [super init])) {
    _bridge = bridge;
    _textures = [NSMutableDictionary dictionary];
    _nextId = 1;
    if (bridge->metal_device != nullptr) {
      id<MTLDevice> device = (__bridge id<MTLDevice>)bridge->metal_device;
      CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &_cache);
    }
  }
  return self;
}

- (void)dealloc {
  for (auto& entry : _frames) entry.second.Clear();
  if (_cache != nullptr) CFRelease(_cache);
}

- (int64_t)registerTexture:(NSObject<FlutterTexture>*)texture {
  int64_t textureId;
  {
    std::lock_guard<std::mutex> lock(_mutex);
    textureId = _nextId++;
    _textures[@(textureId)] = texture;
  }
  if (_cache == nullptr || !_bridge->register_texture(textureId)) {
    std::fprintf(stderr, "🦝 texture %lld: %s\n", static_cast<long long>(textureId),
                 _cache == nullptr ? "textures need the Metal renderer"
                                   : "the engine took no texture");
  }
  return textureId;
}

- (void)textureFrameAvailable:(int64_t)textureId {
  _bridge->mark_texture_frame_available(textureId);
}

- (void)unregisterTexture:(int64_t)textureId {
  _bridge->unregister_texture(textureId);
  NSObject<FlutterTexture>* texture;
  {
    std::lock_guard<std::mutex> lock(_mutex);
    texture = _textures[@(textureId)];
    [_textures removeObjectForKey:@(textureId)];
    const auto frame = _frames.find(textureId);
    if (frame != _frames.end()) {
      frame->second.Clear();
      _frames.erase(frame);
    }
  }
  if ([texture respondsToSelector:@selector(onTextureUnregistered:)]) {
    [texture onTextureUnregistered:texture];
  }
}

// One plane of |buffer| as a Metal texture.
- (CVMetalTextureRef)plane:(size_t)plane
                        of:(CVPixelBufferRef)buffer
                    format:(MTLPixelFormat)format {
  const bool planar = CVPixelBufferIsPlanar(buffer);
  const size_t width = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane)
                              : CVPixelBufferGetWidth(buffer);
  const size_t height = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane)
                               : CVPixelBufferGetHeight(buffer);
  CVMetalTextureRef texture = nullptr;
  CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _cache, buffer, nil, format,
                                            width, height, plane, &texture);
  return texture;
}

// As FlutterMacOS's own external texture does: BGRA in one plane, or
// bi-planar 4:2:0 as Y and UV; nothing else.
- (BOOL)populate:(int64_t)textureId out:(FlutterMetalExternalTexture*)out {
  if (_cache == nullptr) return NO;
  NSObject<FlutterTexture>* texture;
  {
    std::lock_guard<std::mutex> lock(_mutex);
    texture = _textures[@(textureId)];
  }
  if (texture == nil) return NO;
  CVPixelBufferRef buffer = [texture copyPixelBuffer];
  if (buffer == nullptr) return NO;
  TextureFrame next;
  const OSType format = CVPixelBufferGetPixelFormatType(buffer);
  size_t count = 0;
  FlutterMetalExternalTexturePixelFormat pixel_format = kRGBA;
  FlutterMetalExternalTextureYUVColorSpace color_space = kBT601LimitedRange;
  if (format == kCVPixelFormatType_32BGRA) {
    next.planes[0] = [self plane:0 of:buffer format:MTLPixelFormatBGRA8Unorm];
    count = 1;
  } else if (format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
             format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
    next.planes[0] = [self plane:0 of:buffer format:MTLPixelFormatR8Unorm];
    next.planes[1] = [self plane:1 of:buffer format:MTLPixelFormatRG8Unorm];
    count = 2;
    pixel_format = kYUVA;
    if (format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
      color_space = kBT601FullRange;
    }
  } else {
    std::fprintf(stderr, "🦝 texture %lld: pixel format %u not drawn\n",
                 static_cast<long long>(textureId), static_cast<unsigned>(format));
  }
  const size_t width = CVPixelBufferGetWidth(buffer);
  const size_t height = CVPixelBufferGetHeight(buffer);
  CVPixelBufferRelease(buffer);
  for (size_t i = 0; i < count; ++i) {
    if (next.planes[i] == nullptr) {
      next.Clear();
      return NO;
    }
    next.handles[i] = (__bridge FlutterMetalTextureHandle)CVMetalTextureGetTexture(next.planes[i]);
  }
  if (count == 0) return NO;
  std::lock_guard<std::mutex> lock(_mutex);
  TextureFrame& kept = _frames[textureId];
  kept.Clear();
  kept = next;
  out->width = width;
  out->height = height;
  out->pixel_format = pixel_format;
  out->num_textures = count;
  out->textures = kept.handles;
  out->yuv_color_space = color_space;
  return YES;
}

@end

// ---- The registrar ----------------------------------------------------------

@interface RaccoonRegistrar : NSObject <FlutterPluginRegistrar>
- (instancetype)initWithMessenger:(RaccoonMessenger*)messenger
                         textures:(RaccoonTextures*)textures;
@property(nonatomic, readonly, nullable) NSObject* published;
@end

@implementation RaccoonRegistrar {
  RaccoonMessenger* _messenger;
  RaccoonTextures* _textures;
  NSMutableArray<NSObject<FlutterAppLifecycleDelegate>*>* _delegates;
}

- (instancetype)initWithMessenger:(RaccoonMessenger*)messenger
                         textures:(RaccoonTextures*)textures {
  if ((self = [super init])) {
    _messenger = messenger;
    _textures = textures;
    _delegates = [NSMutableArray array];
  }
  return self;
}

- (id<FlutterBinaryMessenger>)messenger {
  return _messenger;
}

- (id<FlutterTextureRegistry>)textures {
  return _textures;
}

// No view: the app's window is the client's pane.
- (NSView*)view {
  return nil;
}

- (NSViewController*)viewController {
  return nil;
}

- (void)addMethodCallDelegate:(id<FlutterPlugin>)delegate channel:(FlutterMethodChannel*)channel {
  [channel setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
    [delegate handleMethodCall:call result:result];
  }];
}

// Kept, so the delegate lives as long as the plugin; the runner has no
// application to report the life cycle of.
- (void)addApplicationDelegate:(NSObject<FlutterAppLifecycleDelegate>*)delegate {
  [_delegates addObject:delegate];
}

- (void)registerViewFactory:(NSObject<FlutterPlatformViewFactory>*)factory
                     withId:(NSString*)factoryId {
  std::fprintf(stderr, "🦝 platform view %s not supported\n", factoryId.UTF8String);
}

- (void)publish:(NSObject*)value {
  _published = value;
}

// The key FlutterMacOS gives: the asset's path inside the app's bundle.
- (NSString*)lookupKeyForAsset:(NSString*)asset {
  return [@"flutter_assets" stringByAppendingPathComponent:asset];
}

- (NSString*)lookupKeyForAsset:(NSString*)asset fromPackage:(NSString*)package {
  return [self lookupKeyForAsset:[NSString stringWithFormat:@"packages/%@/%@", package, asset]];
}

@end

// ---- The host ---------------------------------------------------------------

namespace raccoon {

struct PluginHost::Impl {
  RaccoonMessenger* messenger = nil;
  RaccoonTextures* textures = nil;
  NSMutableArray<RaccoonRegistrar*>* registrars = nil;
};

PluginHost::PluginHost(Bridge bridge) : bridge_(std::move(bridge)), impl_(std::make_unique<Impl>()) {
  impl_->messenger = [[RaccoonMessenger alloc] initWithBridge:&bridge_];
  impl_->textures = [[RaccoonTextures alloc] initWithBridge:&bridge_];
  impl_->registrars = [NSMutableArray array];
  // Plugins that open panels or alerts want an application; as an accessory
  // it has no Dock icon and no menu bar of its own.
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  [NSApp finishLaunching];
}

// The frameworks stay loaded: a plugin's objects may outlive this.
PluginHost::~PluginHost() = default;

bool PluginHost::Prepare(const std::string& flutter_framework, std::string* error) {
  if (flutter_framework.empty()) {
    *error = "no flutter_framework in the manifest: plugins link FlutterMacOS";
    return false;
  }
  // Plugins name it by @rpath; dyld takes this copy for them once it is in.
  // FlutterMacOS and the engine library carry many of the same Objective-C
  // classes (channels, codecs, the Darwin helpers), and the runtime prints
  // a line for each as the framework maps. Same engine revision, nothing
  // to act on: those lines go, anything else printed meanwhile stays.
  fflush(stderr);
  const int saved = dup(STDERR_FILENO);
  FILE* held = tmpfile();
  if (saved >= 0 && held != nullptr) dup2(fileno(held), STDERR_FILENO);
  void* handle = dlopen(flutter_framework.c_str(), RTLD_NOW | RTLD_GLOBAL);
  const std::string why = handle == nullptr ? dlerror() : "";
  int shared = 0;
  if (saved >= 0 && held != nullptr) {
    fflush(stderr);
    dup2(saved, STDERR_FILENO);
    rewind(held);
    char line[4096];
    while (fgets(line, sizeof(line), held) != nullptr) {
      if (std::strstr(line, " is implemented in both ") != nullptr &&
          std::strstr(line, "FlutterMacOS") != nullptr) {
        ++shared;
        continue;
      }
      std::fputs(line, stderr);
    }
  }
  if (held != nullptr) fclose(held);
  if (saved >= 0) close(saved);
  if (shared > 0) {
    std::fprintf(stderr,
                 "🦝 FlutterMacOS shares %d Objective-C classes with the engine "
                 "library, the same revision; the runtime's warnings are left out\n",
                 shared);
  }
  if (handle == nullptr) {
    *error = why;
    return false;
  }
  return true;
}

bool PluginHost::Load(const PluginEntry& entry, std::string* error) {
  if (entry.ffi) {
    // Open to the whole process: Dart finds the symbols there
    // (DynamicLibrary.process) or opens the same file by name.
    if (entry.library.empty() ||
        dlopen(entry.library.c_str(), RTLD_NOW | RTLD_GLOBAL) == nullptr) {
      *error = entry.library.empty() ? "no library" : dlerror();
      return false;
    }
    names_.push_back(entry.name);
    return true;
  }
  if (entry.library.empty() || entry.plugin_class.empty()) {
    *error = "no library or class";
    return false;
  }
  if (dlopen(entry.library.c_str(), RTLD_NOW | RTLD_LOCAL) == nullptr) {
    *error = dlerror();
    return false;
  }
  NSString* name = @(entry.plugin_class.c_str());
  Class cls = nil;
  if (!entry.module.empty()) {
    cls = NSClassFromString([NSString stringWithFormat:@"%s.%@", entry.module.c_str(), name]);
  }
  if (cls == nil) cls = NSClassFromString(name);
  if (cls == nil || ![cls respondsToSelector:@selector(registerWithRegistrar:)]) {
    *error = "no class " + entry.plugin_class + " with registerWithRegistrar: in " + entry.library;
    return false;
  }
  RaccoonRegistrar* registrar = [[RaccoonRegistrar alloc] initWithMessenger:impl_->messenger
                                                                   textures:impl_->textures];
  // Some APIs throw outside an application bundle (UserNotifications does
  // at registration); the plugin fails alone and says why.
  @try {
    [cls registerWithRegistrar:registrar];
  } @catch (NSException* exception) {
    *error = std::string("registerWithRegistrar: threw ") + exception.name.UTF8String + ": " +
             exception.reason.UTF8String;
    return false;
  }
  [impl_->registrars addObject:registrar];
  names_.push_back(entry.name);
  return true;
}

bool PluginHost::HandleMessage(const std::string& channel, const uint8_t* data, size_t size,
                               const FlutterPlatformMessageResponseHandle* handle) {
  @autoreleasepool {
    NSData* message = data == nullptr ? nil : [NSData dataWithBytes:data length:size];
    return [impl_->messenger handleMessage:@(channel.c_str()) data:message handle:handle];
  }
}

bool PluginHost::PopulateTexture(int64_t texture_id, size_t, size_t,
                                 FlutterMetalExternalTexture* out) {
  @autoreleasepool {
    return [impl_->textures populate:texture_id out:out];
  }
}

}  // namespace raccoon
#endif  // RACCOON_HAS_PLUGINS && __APPLE__

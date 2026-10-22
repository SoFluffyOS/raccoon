// The host side of Raccoon's GPU buffers on macOS. Dart asks for a texture,
// names the runner's GPU socket, then names each frame's buffer; this side
// takes the runner's description of its ring from that socket, looks each
// IOSurface up by its ID, wraps it as a pixel buffer, and hands Flutter the
// buffer of the latest frame whenever it asks.
//
// Channel raccoon_view/gpu: create() -> textureId; connect(textureId,
// socket) -> whether buffers go back from here; show(textureId, generation,
// index); dispose(textureId).
//
// No fence crosses the socket: the runner names a frame only once its GPU
// has drawn it, and a buffer goes back to the runner over the same socket
// once the next one is bound, by when the drawing that read it last was
// submitted a frame earlier.
#import "raccoon_view/RaccoonViewPlugin.h"

#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>

#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <vector>

namespace {

// One set of buffers as the runner described it, each surface looked up
// and wrapped; null where the lookup failed.
struct BufferSet {
  uint32_t generation = 0;
  uint32_t width = 0;
  uint32_t height = 0;
  std::vector<CVPixelBufferRef> buffers;

  ~BufferSet() {
    for (CVPixelBufferRef buffer : buffers) {
      if (buffer != nullptr) CVPixelBufferRelease(buffer);
    }
  }
};

uint32_t Read32(const uint8_t* at) {
  return static_cast<uint32_t>(at[0]) | (static_cast<uint32_t>(at[1]) << 8) |
         (static_cast<uint32_t>(at[2]) << 16) | (static_cast<uint32_t>(at[3]) << 24);
}

void Put32(uint8_t* at, uint32_t value) {
  for (int i = 0; i < 4; ++i) at[i] = static_cast<uint8_t>(value >> (8 * i));
}

CVPixelBufferRef WrapSurface(uint32_t surface_id) {
  IOSurfaceRef surface = IOSurfaceLookup(surface_id);
  if (surface == nullptr) return nullptr;
  CVPixelBufferRef buffer = nullptr;
  // The pixel buffer keeps the surface.
  if (CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, nullptr, &buffer) !=
      kCVReturnSuccess) {
    buffer = nullptr;
  }
  CFRelease(surface);
  return buffer;
}

}  // namespace

// ---- The texture ---------------------------------------------------------

@interface RaccoonGpuTexture : NSObject <FlutterTexture>
- (BOOL)connectToSocket:(NSString*)path;
- (void)showGeneration:(uint32_t)generation index:(int)index;
- (void)dispose;
@end

@implementation RaccoonGpuTexture {
  std::mutex _mutex;
  // The set waiting to be shown, and the one shown; the raster thread takes
  // pending over when Flutter asks for a buffer.
  std::unique_ptr<BufferSet> _pending;
  std::unique_ptr<BufferSet> _current;
  uint32_t _shownGeneration;
  int _shownIndex;
  // The buffer handed to Flutter last, -1 for none: given back once another
  // is.
  uint32_t _boundGeneration;
  int _boundIndex;
  // The socket's reading state, on the main queue.
  int _socket;
  dispatch_source_t _reader;
  std::vector<uint8_t> _inbox;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _shownGeneration = 0;
    _shownIndex = -1;
    _boundGeneration = 0;
    _boundIndex = -1;
    _socket = -1;
    _reader = nil;
  }
  return self;
}

// Gives buffer |index| of |generation| back to the runner: 'RREL',
// generation, index, fenced (0: nothing rides along). Mutex held.
- (void)sendRelease:(uint32_t)generation index:(int)index {
  if (_socket < 0) return;
  uint8_t message[4 + 16] = {16, 0, 0, 0, 'R', 'R', 'E', 'L'};
  Put32(message + 8, generation);
  Put32(message + 12, static_cast<uint32_t>(index));
  Put32(message + 16, 0);
  send(_socket, message, sizeof(message), 0);
}

- (CVPixelBufferRef)copyPixelBuffer {
  std::lock_guard<std::mutex> lock(_mutex);
  if (_pending) _current = std::move(_pending);
  if (!_current || _current->buffers.empty()) return nullptr;
  const BufferSet& set = *_current;
  // Nothing of this set shown yet: the first buffer, rather than nothing,
  // and not one to give back.
  int index = 0;
  bool rebound = false;
  uint32_t beforeGeneration = 0;
  int beforeIndex = -1;
  if (_shownGeneration == set.generation && _shownIndex >= 0 &&
      static_cast<size_t>(_shownIndex) < set.buffers.size() &&
      set.buffers[_shownIndex] != nullptr) {
    index = _shownIndex;
    rebound = _boundIndex != _shownIndex || _boundGeneration != set.generation;
    beforeGeneration = _boundGeneration;
    beforeIndex = _boundIndex;
    _boundGeneration = set.generation;
    _boundIndex = _shownIndex;
  }
  // The buffer bound before was last read by the frame drawn before this
  // one: the runner's again.
  if (rebound && beforeIndex >= 0) [self sendRelease:beforeGeneration index:beforeIndex];
  CVPixelBufferRef buffer = set.buffers[index];
  return buffer == nullptr ? nullptr : CVPixelBufferRetain(buffer);
}

- (void)showGeneration:(uint32_t)generation index:(int)index {
  std::lock_guard<std::mutex> lock(_mutex);
  // A frame named but never bound (the raster thread did not get to it)
  // was never read: the runner's again at once.
  const bool superseded =
      _shownIndex >= 0 && (_shownIndex != index || _shownGeneration != generation);
  const bool unbound =
      _shownIndex != _boundIndex || _shownGeneration != _boundGeneration;
  if (superseded && unbound) [self sendRelease:_shownGeneration index:_shownIndex];
  _shownGeneration = generation;
  _shownIndex = index;
}

// ---- The GPU socket ------------------------------------------------------

// Parses the framed sets in the inbox: 'RGPU', generation, count, width,
// height, fourcc, modifier (64 bits), count pairs of stride and offset,
// then count IOSurface IDs. Main queue.
- (void)parseInbox {
  size_t offset = 0;
  while (_inbox.size() - offset >= 4) {
    const uint32_t length = Read32(_inbox.data() + offset);
    if (_inbox.size() - offset - 4 < length) break;
    const uint8_t* payload = _inbox.data() + offset + 4;
    offset += 4 + length;
    if (length < 32 || std::memcmp(payload, "RGPU", 4) != 0) continue;
    const uint32_t count = Read32(payload + 8);
    if (length < 32 + count * 12) continue;  // not whole, or no IDs
    auto set = std::make_unique<BufferSet>();
    set->generation = Read32(payload + 4);
    set->width = Read32(payload + 12);
    set->height = Read32(payload + 16);
    const uint8_t* ids = payload + 32 + count * 8;
    for (uint32_t i = 0; i < count; ++i) {
      set->buffers.push_back(WrapSurface(Read32(ids + i * 4)));
    }
    std::lock_guard<std::mutex> lock(_mutex);
    _pending = std::move(set);
  }
  _inbox.erase(_inbox.begin(), _inbox.begin() + offset);
}

- (void)readSocket {
  uint8_t buffer[16 * 1024];
  const ssize_t got = recv(_socket, buffer, sizeof(buffer), 0);
  if (got <= 0) {
    // The runner hung up: nothing more comes, and releases have nowhere
    // to go.
    [self closeSocket];
    return;
  }
  _inbox.insert(_inbox.end(), buffer, buffer + got);
  [self parseInbox];
}

- (void)closeSocket {
  if (_reader != nil) {
    // Cancelling closes the descriptor, from the cancel handler.
    dispatch_source_cancel(_reader);
    _reader = nil;
  }
  std::lock_guard<std::mutex> lock(_mutex);
  _socket = -1;
}

- (BOOL)connectToSocket:(NSString*)path {
  const char* name = path.UTF8String;
  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  if (name == nullptr || std::strlen(name) >= sizeof(address.sun_path)) return NO;
  std::strcpy(address.sun_path, name);
  const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return NO;
  const int noSigpipe = 1;
  if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0 ||
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, sizeof(noSigpipe)) != 0 ||
      connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
    close(fd);
    return NO;
  }
  {
    std::lock_guard<std::mutex> lock(_mutex);
    _socket = fd;
  }
  _reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, static_cast<uintptr_t>(fd), 0,
                                   dispatch_get_main_queue());
  dispatch_source_set_event_handler(_reader, ^{
    [self readSocket];
  });
  dispatch_source_set_cancel_handler(_reader, ^{
    close(fd);
  });
  dispatch_resume(_reader);
  return YES;
}

- (void)dispose {
  [self closeSocket];
  std::lock_guard<std::mutex> lock(_mutex);
  _pending.reset();
  _current.reset();
}

@end

// ---- The plugin ----------------------------------------------------------

@implementation RaccoonViewPlugin {
  id<FlutterTextureRegistry> _registry;
  NSMutableDictionary<NSNumber*, RaccoonGpuTexture*>* _textures;
}

+ (void)registerWithRegistrar:(id<FlutterPluginRegistrar>)registrar {
  FlutterMethodChannel* channel =
      [FlutterMethodChannel methodChannelWithName:@"raccoon_view/gpu"
                                  binaryMessenger:registrar.messenger];
  RaccoonViewPlugin* plugin = [[RaccoonViewPlugin alloc] initWithRegistry:registrar.textures];
  [registrar addMethodCallDelegate:plugin channel:channel];
}

- (instancetype)initWithRegistry:(id<FlutterTextureRegistry>)registry {
  self = [super init];
  if (self) {
    _registry = registry;
    _textures = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"create"]) {
    RaccoonGpuTexture* texture = [[RaccoonGpuTexture alloc] init];
    const int64_t textureId = [_registry registerTexture:texture];
    _textures[@(textureId)] = texture;
    result(@(textureId));
    return;
  }
  NSDictionary* arguments =
      [call.arguments isKindOfClass:[NSDictionary class]] ? call.arguments : @{};
  NSNumber* textureId = arguments[@"textureId"];
  RaccoonGpuTexture* texture = textureId == nil ? nil : _textures[textureId];
  if (texture == nil) {
    result([FlutterError errorWithCode:@"unknown" message:@"no such texture" details:nil]);
    return;
  }
  if ([call.method isEqualToString:@"connect"]) {
    NSString* socket = arguments[@"socket"];
    if (![socket isKindOfClass:[NSString class]] || ![texture connectToSocket:socket]) {
      result([FlutterError errorWithCode:@"connect"
                                 message:@"could not connect to the GPU socket"
                                 details:nil]);
      return;
    }
    // Buffers go back from here, once drawn.
    result(@YES);
    return;
  }
  if ([call.method isEqualToString:@"show"]) {
    [texture showGeneration:[arguments[@"generation"] unsignedIntValue]
                      index:[arguments[@"index"] intValue]];
    [_registry textureFrameAvailable:textureId.longLongValue];
    result(nil);
    return;
  }
  if ([call.method isEqualToString:@"dispose"]) {
    [_registry unregisterTexture:textureId.longLongValue];
    [texture dispose];
    [_textures removeObjectForKey:textureId];
    result(nil);
    return;
  }
  result(FlutterMethodNotImplemented);
}

@end

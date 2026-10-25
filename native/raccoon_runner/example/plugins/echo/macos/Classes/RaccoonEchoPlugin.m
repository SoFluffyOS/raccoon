// The shape of a Flutter macOS plugin, as `flutter create --template=plugin`
// makes one: a class registered with the registrar, a method channel on its
// messenger. The answer comes from the main queue, so it proves the host
// turns the main run loop. The `texture` method registers a pixel-buffer
// texture of one colour, so a texture's way through the host's renderer can
// be seen too, and the `modal` method runs a modal loop for a while.
#import "RaccoonEchoPlugin.h"

#import <CoreVideo/CoreVideo.h>

// An orange texture, 64 by 64: one BGRA pixel buffer, handed out each frame.
@interface RaccoonEchoTexture : NSObject <FlutterTexture>
@end

@implementation RaccoonEchoTexture {
  CVPixelBufferRef _buffer;
}

- (instancetype)init {
  if ((self = [super init])) {
    NSDictionary* attributes = @{(id)kCVPixelBufferMetalCompatibilityKey : @YES,
                                 (id)kCVPixelBufferIOSurfacePropertiesKey : @{}};
    CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                        (__bridge CFDictionaryRef)attributes, &_buffer);
    CVPixelBufferLockBaseAddress(_buffer, 0);
    uint8_t* pixels = CVPixelBufferGetBaseAddress(_buffer);
    const size_t row_bytes = CVPixelBufferGetBytesPerRow(_buffer);
    for (size_t y = 0; y < 64; ++y) {
      for (size_t x = 0; x < 64; ++x) {
        uint8_t* pixel = pixels + y * row_bytes + x * 4;
        pixel[0] = 0x00;  // B
        pixel[1] = 0x8C;  // G
        pixel[2] = 0xFF;  // R
        pixel[3] = 0xFF;  // A
      }
    }
    CVPixelBufferUnlockBaseAddress(_buffer, 0);
  }
  return self;
}

- (void)dealloc {
  CVPixelBufferRelease(_buffer);
}

// On the raster thread; the caller releases what it gets.
- (CVPixelBufferRef)copyPixelBuffer {
  return CVPixelBufferRetain(_buffer);
}

@end

@implementation RaccoonEchoPlugin {
  NSObject<FlutterTextureRegistry>* _textures;
  RaccoonEchoTexture* _texture;
  int64_t _textureId;
  dispatch_source_t _timer;
}

+ (void)registerWithRegistrar:(id<FlutterPluginRegistrar>)registrar {
  FlutterMethodChannel* channel = [FlutterMethodChannel methodChannelWithName:@"raccoon_echo"
                                                              binaryMessenger:registrar.messenger];
  RaccoonEchoPlugin* plugin = [[RaccoonEchoPlugin alloc] init];
  plugin->_textures = registrar.textures;
  [registrar addMethodCallDelegate:plugin channel:channel];
  // flutter_secure_storage's channel, answering the options that reached
  // the plugin as sorted key=value pairs: the runner rewrites the ones an
  // unsigned process can't have (#87).
  FlutterMethodChannel* secure =
      [FlutterMethodChannel methodChannelWithName:@"plugins.it_nomads.com/flutter_secure_storage"
                                  binaryMessenger:registrar.messenger];
  [secure setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
    NSDictionary* options = [call.arguments isKindOfClass:[NSDictionary class]]
                                ? call.arguments[@"options"]
                                : nil;
    NSMutableArray<NSString*>* pairs = [NSMutableArray array];
    for (NSString* key in [options.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      [pairs addObject:[NSString stringWithFormat:@"%@=%@", key, options[key]]];
    }
    result([pairs componentsJoinedByString:@";"]);
  }];
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"echo"]) {
    NSString* text = [call.arguments isKindOfClass:[NSString class]] ? call.arguments : @"?";
    dispatch_async(dispatch_get_main_queue(), ^{
      result([NSString stringWithFormat:@"echo: %@", text]);
    });
    return;
  }
  if ([call.method isEqualToString:@"texture"]) {
    // Registers the texture once and answers its id. Frames are marked
    // from a background queue at 60 Hz, as a video plugin's display link
    // does, and on until the process ends: the host takes calls from
    // plugin threads, while it shuts down too.
    if (_texture == nil) {
      _texture = [[RaccoonEchoTexture alloc] init];
      _textureId = [_textures registerTexture:_texture];
      NSObject<FlutterTextureRegistry>* textures = _textures;
      const int64_t textureId = _textureId;
      _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                      dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0));
      dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 60, NSEC_PER_MSEC);
      dispatch_source_set_event_handler(_timer, ^{
        [textures textureFrameAvailable:textureId];
      });
      dispatch_resume(_timer);
    }
    result(@(_textureId));
    return;
  }
  if ([call.method isEqualToString:@"modal"]) {
    // A modal window that closes itself after the given milliseconds, as a
    // panel a user dismisses would: its run loop holds the main thread's
    // until then. Out of sight, and never key.
    const double ms = [call.arguments isKindOfClass:[NSNumber class]]
                          ? [call.arguments doubleValue]
                          : 1000;
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(-10000, -10000, 1, 1)
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    window.releasedWhenClosed = NO;
    window.alphaValue = 0;
    // A timer, not an event, ends it: stopModal would wait for an event.
    NSTimer* timer = [NSTimer timerWithTimeInterval:ms / 1000
                                            repeats:NO
                                              block:^(NSTimer* t) {
                                                [NSApp abortModal];
                                              }];
    [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSModalPanelRunLoopMode];
    [NSApp runModalForWindow:window];
    [window close];
    result(@YES);
    return;
  }
  result(FlutterMethodNotImplemented);
}

@end

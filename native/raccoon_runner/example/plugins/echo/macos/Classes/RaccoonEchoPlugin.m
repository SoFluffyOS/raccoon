// The shape of a Flutter macOS plugin, as `flutter create --template=plugin`
// makes one: a class registered with the registrar, a method channel on its
// messenger. The answer comes from the main queue, so it proves the host
// turns the main run loop. The `texture` method registers a pixel-buffer
// texture of one colour, so a texture's way through the host's renderer can
// be seen too.
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
  NSTimer* _timer;
}

+ (void)registerWithRegistrar:(id<FlutterPluginRegistrar>)registrar {
  FlutterMethodChannel* channel = [FlutterMethodChannel methodChannelWithName:@"raccoon_echo"
                                                              binaryMessenger:registrar.messenger];
  RaccoonEchoPlugin* plugin = [[RaccoonEchoPlugin alloc] init];
  plugin->_textures = registrar.textures;
  [registrar addMethodCallDelegate:plugin channel:channel];
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
    // Registers the texture once and answers its id; frames are marked
    // every half second so the host keeps drawing it.
    if (_texture == nil) {
      _texture = [[RaccoonEchoTexture alloc] init];
      _textureId = [_textures registerTexture:_texture];
      NSObject<FlutterTextureRegistry>* textures = _textures;
      const int64_t textureId = _textureId;
      _timer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                               repeats:YES
                                                 block:^(NSTimer* timer) {
                                                   [textures textureFrameAvailable:textureId];
                                                 }];
      [_textures textureFrameAvailable:_textureId];
    }
    result(@(_textureId));
    return;
  }
  result(FlutterMethodNotImplemented);
}

@end

#import <FlutterMacOS/FlutterMacOS.h>

/// The host side of Raccoon's GPU buffers on macOS: a texture fed from the
/// runner's GPU socket. See RaccoonViewPlugin.mm.
@interface RaccoonViewPlugin : NSObject <FlutterPlugin>
@end

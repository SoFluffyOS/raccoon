# flutter_macos, the plugin-facing headers

The public headers of Flutter's `FlutterMacOS.framework`, for the protocols
the runner implements: `FlutterBinaryMessenger`, `FlutterPluginRegistrar`,
`FlutterTextureRegistry`, `FlutterPlugin`. Nothing here is compiled. The
classes behind the headers (the channels, the codecs) stay in the framework
itself, which plugin binaries link against and the runner opens at run time
from the Flutter SDK, before the plugins; the engine behind the messenger is
the runner's.

Everything under `FlutterMacOS/` is verbatim from the framework at the
engine revision in `REVISION`, under `LICENSE`.
`tool/vendor_flutter_macos.sh` refreshes it from the SDK's cache.

# flutter_windows, the plugin-facing headers

The public C headers of Flutter's Windows embedding, `flutter_windows.dll`:
the messenger, the plugin registrar, the texture registrar and the Windows
API (views, window proc delegates, DPI). Plugins call these, through the C++
client wrapper compiled into each plugin. The runner builds a DLL of the
same name implementing them over its own engine (`src/flutter_windows/`),
which plugin binaries then load in place of Flutter's.

Everything under `include/` is verbatim from the Flutter SDK's
`windows-x64` engine artifacts at the engine revision in `REVISION`, under
`LICENSE`. `tool/vendor_flutter_windows.sh` refreshes it from the SDK's
cache.

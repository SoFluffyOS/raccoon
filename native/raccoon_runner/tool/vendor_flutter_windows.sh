#!/bin/sh
# Copies the public C headers of Flutter's Windows embedding at one engine
# revision into third_party/flutter_windows: the messenger, plugin
# registrar, texture registrar and Windows API that plugins call in
# flutter_windows.dll. The runner builds a DLL of that name implementing
# them over its own engine; only the headers are needed for that. Plugins
# themselves build against the SDK's copies and its C++ client wrapper.
# They come from the Flutter SDK's cache (flutter precache --windows).
#
#   tool/vendor_flutter_windows.sh [flutter-sdk]
#
# Without an SDK, the one on the PATH is used.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/third_party/flutter_windows"
sdk="${1:-}"
if [ -z "$sdk" ]; then
  flutter_bin="$(command -v flutter)"
  sdk="$(cd "$(dirname "$(readlink -f "$flutter_bin")")/.." && pwd)"
fi
headers="$sdk/bin/cache/artifacts/engine/windows-x64"
if [ ! -f "$headers/flutter_windows.h" ]; then
  echo "no flutter_windows.h in $sdk; run flutter precache --windows" >&2
  exit 1
fi
rm -rf "$out/include"
mkdir -p "$out/include"
for header in flutter_export.h flutter_messenger.h flutter_plugin_registrar.h \
    flutter_texture_registrar.h flutter_windows.h; do
  cp "$headers/$header" "$out/include/"
done
cp "$sdk/LICENSE" "$out/LICENSE"
cat "$sdk/bin/internal/engine.version" > "$out/REVISION"
echo "vendored the Windows embedding's headers at $(cat "$out/REVISION")"

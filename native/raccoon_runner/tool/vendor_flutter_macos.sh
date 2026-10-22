#!/bin/sh
# Copies the public headers of FlutterMacOS.framework at one engine revision
# into third_party/flutter_macos: the messenger, registrar, texture and
# plugin protocols the runner implements over its own engine. The classes
# behind them (channels, codecs) stay in the framework, which plugins link
# against and the runner opens at run time; only the headers are needed to
# build. They come from the Flutter SDK's cache (flutter precache --macos).
#
#   tool/vendor_flutter_macos.sh [flutter-sdk]
#
# Without an SDK, the one on the PATH is used.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/third_party/flutter_macos"
sdk="${1:-}"
if [ -z "$sdk" ]; then
  flutter_bin="$(command -v flutter)"
  sdk="$(cd "$(dirname "$(readlink -f "$flutter_bin")")/.." && pwd)"
fi
headers="$sdk/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64/FlutterMacOS.framework/Headers"
if [ ! -d "$headers" ]; then
  echo "no FlutterMacOS headers in $sdk; run flutter precache --macos" >&2
  exit 1
fi
rm -rf "$out/FlutterMacOS"
mkdir -p "$out/FlutterMacOS"
cp "$headers"/*.h "$out/FlutterMacOS/"
cp "$sdk/LICENSE" "$out/LICENSE"
cat "$sdk/bin/internal/engine.version" > "$out/REVISION"
echo "vendored FlutterMacOS headers at $(cat "$out/REVISION")"

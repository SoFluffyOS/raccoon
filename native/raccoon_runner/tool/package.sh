#!/usr/bin/env bash
# Packs the built runner for a release: the binary, the custom device helper,
# the engine fetcher, VERSION and LICENSE, flat in
# raccoon_runner-<version>-<platform>.tar.gz, where the platform is linux-x64,
# linux-arm64, macos-arm64 or macos-x64. Unpacked into a folder, tool/
# raccoon-device finds the binary beside it, so the folder works as a runtime
# on its own. Prints the archive's path.
#
#   tool/package.sh [output directory]      # default: build/dist
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BINARY="$ROOT/build/raccoon_runner"
if [ ! -x "$BINARY" ]; then
  echo "no $BINARY; build the runner first" >&2
  exit 1
fi

case "$(uname -s)" in
  Darwin) OS=macos ;;
  Linux) OS=linux ;;
  *) echo "unsupported system $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64) ARCH=x64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

NAME="raccoon_runner-$VERSION-$OS-$ARCH"
OUT="${1:-$ROOT/build/dist}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/tool" "$OUT"
cp "$BINARY" "$STAGE/raccoon_runner"
cp "$ROOT/tool/raccoon-device" "$ROOT/tool/engine_dir.sh" "$STAGE/tool/"
cp "$ROOT/VERSION" "$ROOT/LICENSE" "$STAGE/"
chmod 755 "$STAGE/raccoon_runner" "$STAGE/tool/"*
# No AppleDouble (._*) entries from macOS's tar.
CONTENTS="raccoon_runner tool VERSION LICENSE"
# The plugin-facing library and its headers, where the runner was built
# with them: a project's native plugins build against these.
if [ -f "$ROOT/build/libflutter_linux_gtk.so" ]; then
  cp "$ROOT/build/libflutter_linux_gtk.so" "$STAGE/"
  mkdir -p "$STAGE/include"
  cp -r "$ROOT/third_party/flutter_linux/flutter/shell/platform/linux/public/flutter_linux" "$STAGE/include/"
  cp "$ROOT/third_party/flutter_linux/LICENSE" "$STAGE/LICENSE.flutter"
  CONTENTS="$CONTENTS libflutter_linux_gtk.so include LICENSE.flutter"
fi
# shellcheck disable=SC2086
COPYFILE_DISABLE=1 tar -C "$STAGE" -czf "$OUT/$NAME.tar.gz" $CONTENTS
echo "$OUT/$NAME.tar.gz"

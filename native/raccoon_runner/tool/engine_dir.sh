#!/usr/bin/env bash
# Prints the runtime directory for the active Flutter SDK's engine revision,
# downloading the prebuilt debug embedder when missing: flutter_embedder.h and
# libflutter_engine.so on Linux, FlutterEmbedder.framework on macOS,
# flutter_embedder.h and flutter_engine.dll on Windows (from Git Bash, which
# every Flutter install there has; the path comes out as C:/...). Reads the
# SDK's engine stamp when it can, which is much faster than asking the tool.
set -euo pipefail

sdk_root() {
  # The Flutter tool exports FLUTTER_ROOT to the commands it runs, such as the
  # custom device helper; IDEs often start flutter without it on PATH.
  if [ -n "${FLUTTER_ROOT:-}" ] && [ -x "$FLUTTER_ROOT/bin/flutter" ]; then
    echo "$FLUTTER_ROOT"
    return 0
  fi
  local flutter
  flutter="$(command -v flutter)" || return 1
  flutter="$(readlink -f "$flutter")"
  echo "$(cd "$(dirname "$flutter")/.." && pwd)"
}

REV=""
if SDK="$(sdk_root)" && [ -f "$SDK/bin/cache/engine.stamp" ]; then
  REV="$(cat "$SDK/bin/cache/engine.stamp")"
fi
if [ -z "$REV" ]; then
  REV="$(flutter --version --machine 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["engineRevision"])')"
fi

BUCKET="https://storage.googleapis.com/flutter_infra_release/flutter/$REV"
CACHE="${RACCOON_ENGINE_CACHE:-$HOME/.cache/raccoon/engines}/$REV"
case "$(uname -s)" in
  Darwin)
    # One universal framework serves both Mac architectures.
    DIR="$CACHE/darwin"
    LIBRARY="$DIR/FlutterEmbedder.framework/FlutterEmbedder"
    URL="$BUCKET/darwin-x64/FlutterEmbedder.framework.zip"
    UNZIP_INTO="$DIR/FlutterEmbedder.framework"
    ;;
  Linux)
    case "$(uname -m)" in
      x86_64) PLATFORM=linux-x64 ;;
      aarch64|arm64) PLATFORM=linux-arm64 ;;
      *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
    esac
    DIR="$CACHE/$PLATFORM"
    LIBRARY="$DIR/libflutter_engine.so"
    URL="$BUCKET/$PLATFORM/$PLATFORM-embedder.zip"
    UNZIP_INTO="$DIR"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    case "${PROCESSOR_ARCHITEW6432:-${PROCESSOR_ARCHITECTURE:-}}" in
      AMD64) PLATFORM=windows-x64 ;;
      ARM64) PLATFORM=windows-arm64 ;;
      *) echo "unsupported architecture ${PROCESSOR_ARCHITECTURE:-}" >&2; exit 1 ;;
    esac
    DIR="$CACHE/$PLATFORM"
    LIBRARY="$DIR/flutter_engine.dll"
    URL="$BUCKET/$PLATFORM/$PLATFORM-embedder.zip"
    UNZIP_INTO="$DIR"
    ;;
  *) echo "unsupported system $(uname -s)" >&2; exit 1 ;;
esac

# An engine is there once its library is, unless a download that wrote in
# place, before #136, was cut short: its dl folder is left behind.
installed() { [ -e "$LIBRARY" ] && [ ! -d "$DIR/dl" ]; }
if ! installed; then
  # Downloaded and unpacked aside, then renamed into place, as RuntimeStore
  # does: an interrupted download, or two at once, never leaves half an
  # engine that counts as there (#136).
  mkdir -p "$CACHE"
  STAGE="$(mktemp -d "$DIR.partial.XXXXXX")"
  trap 'rm -rf "$STAGE"' EXIT
  mkdir -p "$STAGE/dir${UNZIP_INTO#"$DIR"}"
  # Said plainly: offline, a first run with a new SDK fails here (#119).
  if ! curl -sfLo "$STAGE/embedder.zip" "$URL" ||
    ! unzip -q -o "$STAGE/embedder.zip" -d "$STAGE/dir${UNZIP_INTO#"$DIR"}"; then
    echo "🦝 could not download the Flutter engine $REV from $URL; check the network" >&2
    exit 1
  fi
  rm -f "$STAGE/embedder.zip"
  # Another download may have finished first; its engine is as good.
  if ! installed; then
    rm -rf "$DIR"
    [ -e "$DIR" ] || mv "$STAGE/dir" "$DIR"
  fi
fi
if command -v cygpath >/dev/null; then cygpath -m "$DIR"; else echo "$DIR"; fi

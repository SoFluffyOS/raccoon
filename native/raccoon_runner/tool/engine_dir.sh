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
# The stamp, else the revision the SDK pins; either may end in CRLF on
# Windows.
if SDK="$(sdk_root)"; then
  for stamp in "$SDK/bin/cache/engine.stamp" "$SDK/bin/internal/engine.version"; do
    [ -f "$stamp" ] || continue
    # Read in the shell, CR and all spaces dropped: a run asks this every
    # launch, and tr was a process (#323).
    IFS= read -r REV < "$stamp" || true
    REV="${REV//[[:space:]]/}"
    [ -n "$REV" ] && break
  done
fi
if [ -z "$REV" ]; then
  if ! command -v flutter >/dev/null; then
    echo "🦝 no Flutter SDK: set FLUTTER_ROOT or put flutter on PATH" >&2
    exit 1
  fi
  REV="$(flutter --version --machine 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["engineRevision"])')"
fi

# Where Flutter itself downloads from: a mirror where Google's storage is
# out of reach (storage.flutter-io.cn in mainland China).
STORAGE="${FLUTTER_STORAGE_BASE_URL:-https://storage.googleapis.com}"
BUCKET="${STORAGE%/}/flutter_infra_release/flutter/$REV"
CACHE="${RACCOON_ENGINE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/raccoon/engines}/$REV"
# The device helper passes what uname said to it; run on its own, it asks.
SYSTEM="${UNAME_S:-$(uname -s)}"
case "$SYSTEM" in
  Darwin)
    # One universal framework serves both Mac architectures.
    DIR="$CACHE/darwin"
    LIBRARY="$DIR/FlutterEmbedder.framework/FlutterEmbedder"
    URL="$BUCKET/darwin-x64/FlutterEmbedder.framework.zip"
    UNZIP_INTO="$DIR/FlutterEmbedder.framework"
    ;;
  Linux)
    MACHINE="${UNAME_M:-$(uname -m)}"
    case "$MACHINE" in
      x86_64) PLATFORM=linux-x64 ;;
      aarch64|arm64) PLATFORM=linux-arm64 ;;
      *) echo "unsupported architecture $MACHINE" >&2; exit 1 ;;
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
  *) echo "unsupported system $SYSTEM" >&2; exit 1 ;;
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
  # A connection that stalls fails rather than hold the launch silent.
  if ! curl -sfL --connect-timeout 30 --speed-limit 1024 --speed-time 60 \
      -o "$STAGE/embedder.zip" "$URL" ||
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

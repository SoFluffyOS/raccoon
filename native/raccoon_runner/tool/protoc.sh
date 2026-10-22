#!/usr/bin/env bash
# Installs a user-local protoc matching the protobuf the runner builds
# (21.12 == libprotobuf 3.21.12). No sudo needed. Prints the binary's path,
# as C:/... on Windows, which CMake takes as it is.
set -euo pipefail

VERSION="${PROTOC_VERSION:-21.12}"
DIR="${RACCOON_PROTOC_DIR:-$HOME/.local/raccoon/protoc}"
EXE=""
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE=.exe ;; esac
if [ ! -x "$DIR/bin/protoc$EXE" ]; then
  case "$(uname -s)" in
    Darwin) BUILD=osx-universal_binary ;;
    Linux)
      case "$(uname -m)" in
        x86_64) BUILD=linux-x86_64 ;;
        aarch64|arm64) BUILD=linux-aarch_64 ;;
        *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
      esac
      ;;
    # One x64 build; Windows on Arm runs it emulated.
    MINGW*|MSYS*|CYGWIN*) BUILD=win64 ;;
    *) echo "unsupported system $(uname -s)" >&2; exit 1 ;;
  esac
  mkdir -p "$DIR/dl"
  curl -sfLo "$DIR/dl/protoc.zip" \
    "https://github.com/protocolbuffers/protobuf/releases/download/v$VERSION/protoc-$VERSION-$BUILD.zip"
  unzip -q -o "$DIR/dl/protoc.zip" -d "$DIR"
  rm -rf "$DIR/dl"
  chmod +x "$DIR/bin/protoc$EXE"
fi
if [ -n "$EXE" ]; then cygpath -m "$DIR/bin/protoc$EXE"; else echo "$DIR/bin/protoc"; fi

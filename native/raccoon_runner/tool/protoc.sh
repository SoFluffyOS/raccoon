#!/usr/bin/env bash
# Installs a user-local protoc matching the protobuf the runner builds
# (21.12 == libprotobuf 3.21.12). No sudo needed. Prints the binary's path.
set -euo pipefail

VERSION="${PROTOC_VERSION:-21.12}"
DIR="${RACCOON_PROTOC_DIR:-$HOME/.local/raccoon/protoc}"
if [ ! -x "$DIR/bin/protoc" ]; then
  case "$(uname -m)" in
    x86_64) ARCH=x86_64 ;;
    aarch64|arm64) ARCH=aarch_64 ;;
    *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
  esac
  mkdir -p "$DIR/dl"
  curl -sfLo "$DIR/dl/protoc.zip" \
    "https://github.com/protocolbuffers/protobuf/releases/download/v$VERSION/protoc-$VERSION-linux-$ARCH.zip"
  unzip -q -o "$DIR/dl/protoc.zip" -d "$DIR"
  rm -rf "$DIR/dl"
  chmod +x "$DIR/bin/protoc"
fi
echo "$DIR/bin/protoc"

#!/usr/bin/env bash
# Prints the cache directory holding flutter_embedder.h and libflutter_engine.so
# for the active Flutter SDK's engine revision, downloading it when missing.
set -euo pipefail

REV="$(flutter --version --machine 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["engineRevision"])')"
DIR="${RACCOON_ENGINE_CACHE:-$HOME/.cache/raccoon/engines}/$REV/linux-x64"
if [ ! -f "$DIR/libflutter_engine.so" ]; then
  mkdir -p "$DIR/dl"
  curl -sfLo "$DIR/dl/linux-x64-embedder.zip" \
    "https://storage.googleapis.com/flutter_infra_release/flutter/$REV/linux-x64/linux-x64-embedder.zip"
  unzip -q -o "$DIR/dl/linux-x64-embedder.zip" -d "$DIR"
  rm -rf "$DIR/dl"
fi
echo "$DIR"

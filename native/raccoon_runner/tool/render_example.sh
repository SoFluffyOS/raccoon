#!/usr/bin/env bash
# End to end on Linux: fetch the engine, build the example bundle and the
# runner, render a frame, convert it to build/frame.png.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_DIR="$("$ROOT/tool/engine_dir.sh")"
SDK_ENGINE="$(dirname "$(dirname "$(command -v flutter)")")/bin/cache/artifacts/engine/linux-x64"

(cd "$ROOT/example/hello" && flutter build bundle --target-platform=linux-x64 >/dev/null)

cmake -S "$ROOT" -B "$ROOT/build" -G Ninja -DRACCOON_ENGINE_DIR="$ENGINE_DIR" >/dev/null
ninja -C "$ROOT/build" >/dev/null

"$ROOT/build/raccoon_runner" \
  --engine-dir "$ENGINE_DIR" \
  --assets "$ROOT/example/hello/build/flutter_assets" \
  --icu "$SDK_ENGINE/icudtl.dat" \
  --out "$ROOT/build/frame.ppm" "$@"

python3 -c "from PIL import Image; Image.open('$ROOT/build/frame.ppm').save('$ROOT/build/frame.png')"
echo "$ROOT/build/frame.png"

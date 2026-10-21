#!/usr/bin/env bash
# End to end on the host: fetch the engine, build the example bundle and the
# runner, render a frame, convert it to build/frame.png.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_DIR="$("$ROOT/tool/engine_dir.sh")"
SDK="$(dirname "$(dirname "$(readlink -f "$(command -v flutter)")")")"
case "$(uname -s)" in
  Darwin) TARGET=darwin; SDK_ENGINE=darwin-x64 ;;
  Linux)
    case "$(uname -m)" in
      x86_64) TARGET=linux-x64 ;;
      aarch64|arm64) TARGET=linux-arm64 ;;
      *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
    esac
    SDK_ENGINE=$TARGET
    ;;
  *) echo "unsupported system $(uname -s)" >&2; exit 1 ;;
esac

(cd "$ROOT/example/hello" && flutter build bundle --target-platform=$TARGET >/dev/null)

cmake -S "$ROOT" -B "$ROOT/build" -G Ninja -DRACCOON_ENGINE_DIR="$ENGINE_DIR" >/dev/null
ninja -C "$ROOT/build" >/dev/null

"$ROOT/build/raccoon_runner" render \
  --engine-dir "$ENGINE_DIR" \
  --assets "$ROOT/example/hello/build/flutter_assets" \
  --icu "$SDK/bin/cache/artifacts/engine/$SDK_ENGINE/icudtl.dat" \
  --out "$ROOT/build/frame.ppm" "$@"

python3 -c "from PIL import Image; Image.open('$ROOT/build/frame.ppm').save('$ROOT/build/frame.png')"
echo "$ROOT/build/frame.png"

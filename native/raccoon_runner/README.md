# raccoon_runner

The Raccoon runtime's runner: hosts a Flutter app on the C embedder API, for
Lumide. A git submodule of the Lumide monorepo at `native/raccoon_runner`.
Design notes: `docs/internal_docs/raccoon/`.

## What it does

- Loads the prebuilt debug embedder for the active SDK's engine revision at
  run time (`tool/engine_dir.sh` downloads it: `libflutter_engine.so` on
  Linux, `FlutterEmbedder.framework` on macOS), so one runner binary serves
  several runtimes.
- Runs an app bundle (`build/flutter_assets`, no native build needed) with the
  software renderer on a pumped platform task runner.
- `serve`: speaks runner protocol v1 (`proto/raccoon/v1/runner.proto`) over a
  Unix socket: length-prefixed protobuf; frames out as pixels in the host's
  native order (BGRA on Linux, RGBA on macOS), through shared buffers when the
  client takes them; resize, pointer and key events in; the app's platform
  channel messages out and the client's answers back; the VM service URI;
  shutdown.
- Answers the window plugins' channels itself (`desktop_window`,
  `window_manager`, `window_size`), in both commands and with or without a
  client: the app's window is the client's pane, so sizes come from the view
  and requests to resize, move or go full screen are recorded, not applied.
  Desktop apps call these at startup (Wonderous before its first frame), and
  an unanswered call throws. `example/window` checks the answers.
- `render`: writes one frame to a PPM file, for tests and a quick look.
- `tool/raccoon-device`: ping, install, uninstall and run for the Flutter
  tool's custom device, so a stock `flutter run -d raccoon` works.

## Build

Linux needs a C++17 compiler, CMake and Ninja; macOS the Xcode command-line
tools plus `brew install cmake ninja`.

```sh
tool/protoc.sh                       # user-local protoc 21.12, once
cmake -S . -B build -G Ninja -DRACCOON_ENGINE_DIR="$(tool/engine_dir.sh)"
ninja -C build                       # first build also compiles protobuf-lite
```

## Try it

```sh
tool/render_example.sh               # build/frame.png of example/hello
```

Serve the example and look at it from `packages/raccoon_view/example`:

```sh
build/raccoon_runner serve \
  --engine-dir "$(tool/engine_dir.sh)" \
  --assets example/hello/build/flutter_assets \
  --icu "$FLUTTER_SDK/bin/cache/artifacts/engine/linux-x64/icudtl.dat" \
  --socket "$XDG_RUNTIME_DIR/raccoon/hello.sock"
```

On macOS the ICU data is under `engine/darwin-x64` and the sockets live in
`$TMPDIR/raccoon`, which is where `tool/raccoon-device` puts them.

Register the custom device and run any project on it:

```sh
flutter config --enable-custom-devices
(cd ../../packages/raccoon_runtime && dart run raccoon_runtime:raccoon_device setup --helper "$PWD/tool/raccoon-device")
flutter run -d raccoon
```

The integration tests in `packages/raccoon_runtime` drive the real runner.

## Benchmark: clean build to first frame

Compares the host's desktop device with Raccoon on Flutter Wonderous:

```sh
P="$(tool/bench/wonderous.sh)"           # clone, add the first-frame probe, add the platform folder
python3 tool/bench/first_frame.py "$P"   # 3 rounds each, flutter clean before every run
python3 tool/bench/first_frame.py "$P" --warm   # the same without flutter clean
```

The Raccoon device must be registered first (see above).

## Protocol changes

Edit `proto/raccoon/v1/runner.proto`, rebuild (CMake regenerates the C++),
and run `pub_packages/raccoon/tool/gen_proto.sh` for the Dart side. Bump
`RaccoonProtocol.version` on incompatible changes.

## Hosts

Linux and macOS, from the same sources; the per-host seams are the wake
descriptor (eventfd or a pipe), socket flags, the shared buffers' backing
(a memfd, or an unlinked temporary file on macOS, whose POSIX shared memory
cannot be read with `read()`), the engine library's name and the pixel
order. Windows follows the same seams.

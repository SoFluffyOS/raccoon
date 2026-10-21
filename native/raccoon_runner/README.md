# raccoon_runner

The Raccoon runtime's runner: hosts a Flutter app on the C embedder API, for
Lumide. A git submodule of the Lumide monorepo at `native/raccoon_runner`.
Design notes: `docs/internal_docs/raccoon/`.

## What it does

- Loads `libflutter_engine.so` for the active SDK's engine revision at run
  time (`tool/engine_dir.sh` downloads the prebuilt debug embedder), so one
  runner binary serves several runtimes.
- Runs an app bundle (`build/flutter_assets`, no native build needed) with the
  software renderer on a pumped platform task runner.
- `serve`: speaks runner protocol v1 (`proto/raccoon/v1/runner.proto`) over a
  Unix socket: length-prefixed protobuf; frames out as BGRA pixels; resize,
  pointer and key events in; the app's platform channel messages out and the
  client's answers back; the VM service URI; shutdown.
- `render`: writes one frame to a PPM file, for tests and a quick look.
- `tool/raccoon-device`: ping, install, uninstall and run for the Flutter
  tool's custom device, so a stock `flutter run -d raccoon` works.

## Build

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

Register the custom device and run any project on it:

```sh
flutter config --enable-custom-devices
(cd ../../packages/raccoon_runtime && dart run raccoon_runtime:raccoon_device setup --helper "$PWD/tool/raccoon-device")
flutter run -d raccoon
```

The integration tests in `packages/raccoon_runtime` drive the real runner.

## Protocol changes

Edit `proto/raccoon/v1/runner.proto`, rebuild (CMake regenerates the C++),
and run `pub_packages/raccoon/tool/gen_proto.sh` for the Dart side. Bump
`RaccoonProtocol.version` on incompatible changes.

Linux first, on the developer's workstation. The per-host seams (engine
loading, sockets, paths) are small so macOS and Windows follow.

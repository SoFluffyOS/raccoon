# raccoon_runner

[![CI](https://github.com/SoFluffyOS/raccoon_runner/actions/workflows/ci.yml/badge.svg)](https://github.com/SoFluffyOS/raccoon_runner/actions/workflows/ci.yml)

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
- Answers some plugins' channels itself, in both commands and with or
  without a client, because apps call them at startup (Wonderous before its
  first frame) and an unanswered call throws:
  - the window plugins (`desktop_window`, `window_manager`, `window_size`):
    the app's window is the client's pane, so sizes come from the view and
    requests to resize, move or go full screen are recorded, not applied;
  - `shared_preferences_foundation`, which a Mac host's Dart VM picks (it
    reports macOS), kept in `--data-dir` when given (`tool/raccoon-device`
    passes one per app), in memory otherwise.
  On Linux the app's Dart VM picks the Dart-only `path_provider_linux` and
  `shared_preferences_linux`, which name their directories after the
  executable: with `--data-dir` the runner points `XDG_DATA_HOME` and
  `XDG_CACHE_HOME` into it, so apps do not share one.
  `example/channels` checks the answers.
- Delivers keys the way the framework expects: the key data, then the
  legacy `flutter/keyevent` message it waits for before dispatching. Without
  the second, no key ever reaches the app.
- Types: it answers `flutter/textinput` and keeps the active field's editing
  state, so the keys the framework leaves unhandled insert text, delete,
  move and act; `example/text` shows it. Composition (an IME) is not here yet.
- Rasterizes on the GPU where the host offers one without a window: through
  EGL on Linux (Mesa: the surfaceless platform or a render node), through
  Metal on macOS. By default each frame is read back as pixels in the
  host's order, so clients see the same frames as from the software
  renderer; at 2400×1600 that halves the runner's CPU. A client that asks
  for `gpu_buffers` gets a ring of four textures instead, exported as DRM
  dmabufs on Linux and backed by IOSurfaces on macOS: the engine draws
  straight into them and a frame is the index of its buffer, no pixels. The
  ring is described over a second socket, the main one's path with `.gpu`
  in place of `.sock` (its layout is in `main.cc`). On Linux the
  descriptors ride along, and a native fence goes ahead of every frame
  where EGL has them; on macOS the message names the surfaces by ID, and a
  frame leaves once the GPU has drawn it. A buffer goes back on either
  socket, with a fence of its own on the second where there are fences. The
  raccoon_view plugin does this on Linux and macOS. `--renderer
  auto|gl|metal|software`, or `RACCOON_RENDERER` in the environment: `auto`
  falls back to software; the start-up log says which is in use, and
  `RACCOON_TRACE=1` traces every frame's buffer. On Linux, built when `egl`
  and `glesv2` are found by pkg-config (`libegl1-mesa-dev
  libgles2-mesa-dev` on Debian).
- `render`: writes one frame to a PPM file, for tests and a quick look.
- `tool/raccoon-device`: ping, install, uninstall and run for the Flutter
  tool's custom device, so a stock `flutter run -d raccoon` works.
  `--instance N` names everything `<app>@N`, which is how the `raccoon-N`
  devices keep a second run of the same project apart; each run's output
  lands timestamped in the app's data directory as `runner.log`.

## Build

Linux needs a C++17 compiler, CMake and Ninja; macOS the Xcode command-line
tools plus `brew install cmake ninja`.

```sh
tool/protoc.sh                       # user-local protoc 21.12, once
cmake -S . -B build -G Ninja -DRACCOON_ENGINE_DIR="$(tool/engine_dir.sh)"
ninja -C build                       # first build also compiles protobuf-lite
```

CI (`.github/workflows/ci.yml`) does the same on Linux x64 and both Mac
architectures, bundles the examples, renders a frame, and runs
`raccoon_runtime`'s tests, whose integration tests drive the built runner.

## Prebuilt binaries

Every tag `v<VERSION>` publishes `raccoon_runner-<version>-<platform>.tar.gz`
for `linux-x64`, `macos-arm64` and `macos-x64` on the [releases
page](https://github.com/SoFluffyOS/raccoon_runner/releases), packed by
`tool/package.sh`: the binary, `tool/raccoon-device`, `tool/engine_dir.sh`,
`VERSION` and `LICENSE`, flat. Unpacked into a folder it works as a runtime
on its own, and the Raccoon Simulator fetches the archive for its host
itself.

```sh
mkdir raccoon_runner && tar xzf raccoon_runner-<version>-<platform>.tar.gz -C raccoon_runner
raccoon_runner/raccoon_runner --version
raccoon_runner/tool/raccoon-device ping    # finds the binary beside it
```

The binaries are not notarized. macOS quarantines a browser download, so
clear that before the first run: `xattr -d com.apple.quarantine
raccoon_runner/raccoon_runner`. A download by a tool carries no quarantine
attribute.

`VERSION` holds the version, which `--version` prints; a `-pre.N` suffix
marks a prerelease. To release, bump `VERSION`, commit, and push the tag
`v$(cat VERSION)`: `.github/workflows/release.yml` refuses a tag that does
not match.

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
cannot be read with `read()`), the GPU renderer (EGL and dmabufs, or Metal
and IOSurfaces), the engine library's name and the pixel order. Windows
follows the same seams.

## Issues

Report here: [SoFluffyOS/raccoon](https://github.com/SoFluffyOS/raccoon/issues). One tracker for every Raccoon repository, whichever piece the bug is in. Issues are off on this one.

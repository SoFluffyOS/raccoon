# raccoon_runner

[![CI](https://github.com/SoFluffyOS/raccoon_runner/actions/workflows/ci.yml/badge.svg)](https://github.com/SoFluffyOS/raccoon_runner/actions/workflows/ci.yml)

The Raccoon runtime's runner: hosts a Flutter app on the C embedder API, for
Lumide. Part of the [raccoon](https://github.com/SoFluffyOS/raccoon) repository at `native/raccoon_runner`; Lumide and the simulator take that repository as a git submodule.
Design notes: `docs/internal_docs/raccoon/`.

## What it does

- Loads the prebuilt debug embedder for the active SDK's engine revision at
  run time (`tool/engine_dir.sh` downloads it: `libflutter_engine.so` on
  Linux, `FlutterEmbedder.framework` on macOS, `flutter_engine.dll` on
  Windows), so one runner binary serves several runtimes.
- Runs an app bundle (`build/flutter_assets`, no native build needed) with the
  software renderer on a pumped platform task runner.
- `serve`: speaks runner protocol v1 (`proto/raccoon/v1/runner.proto`) over a
  Unix socket (Windows has them too): length-prefixed protobuf; frames out as
  pixels in the host's native order (BGRA on Linux and Windows, RGBA on
  macOS), through shared buffers when the client takes them, inline on
  Windows; resize, pointer and key events in; the app's platform
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
- Loads the project's native plugins on Linux, instead of answering their
  channels itself. A plugin binary links against `libflutter_linux_gtk.so`;
  the runner ships one of its own with the plugin-facing half of Flutter's
  Linux embedding vendored (`third_party/flutter_linux`: `FlValue`, the
  codecs and channels, the messenger, registrar and texture interfaces),
  and behind it the engine is this runner. `--plugins MANIFEST` names the
  libraries and their register symbols; `tool/raccoon-device install`
  writes that manifest after building the plugins the project resolves
  (`.dart_tool/package_config.json`, every package with a Linux
  `pluginClass`) in one CMake project with what the desktop template gives
  a plugin, and `run` passes it. Needs cmake, ninja, pkg-config and the
  GTK development files, as the desktop target does; what built is cached
  by plugin version, runner version and engine, and a release's archive of
  the common plugins (`tool/plugins`, built by CI) drops into that cache
  on the first install, so those cost nothing and a machine without a
  toolchain still gets them. Without a toolchain for the rest, or when a
  plugin fails to build, it says so and the app sees no plugin. A
  loaded plugin's channels are answered before a client sees them, GLib's
  main context is pumped from the runner's loop, and a plugin's textures
  draw through the GL renderer. The registrar hands out no view: the
  window plugins (`desktop_window`, `window_manager`, `window_size`,
  `screen_retriever`) stay the runner's own, above. `example/plugins/echo`
  is a plugin as the template makes one; `example/plugins_app` calls it.
- Loads the project's native plugins on macOS too. A plugin framework links
  against `FlutterMacOS.framework` and uses its channel and codec classes;
  the runner opens the Flutter SDK's copy at run time, before the plugins,
  and implements the protocols they are handed (`FlutterBinaryMessenger`,
  background task queues included, `FlutterPluginRegistrar` with no view,
  `FlutterTextureRegistry`) over its own engine, from the public headers
  alone (`third_party/flutter_macos`). The manifest names that framework
  and each plugin's binary and class (`module.Class` for Swift);
  `tool/raccoon-device install` builds the plugins the project resolves
  (every package with a macOS `pluginClass`, in `macos/` or a shared
  `darwin/`) as CocoaPods does for a macOS app, but without the app's Xcode
  project: one scratch Pods project for what the cache misses, every pod
  a dynamic framework, each plugin's target built on its own. Needs Xcode
  and CocoaPods, as the macOS target does; cached the same way as on Linux,
  and a release's archive of the common plugins (both Mac architectures)
  drops into that cache on the first install: the fifteen of `tool/plugins`
  in under a second instead of 2 min.
  `run` starts the runner of an app with plugins through a bundle of the
  app's own (`<app>.app`, identifier `dev.raccoon.app.<app>`, a symlink to
  the runner), because some of Apple's APIs throw without one. While
  plugins are loaded the runner waits in the main run loop instead of
  poll(2), so the main queue, timers and AppKit's events run (it starts as
  an accessory application, no Dock icon); a plugin's textures, BGRA or
  bi-planar YUV pixel buffers, draw through the Metal renderer. An
  Objective-C exception from a plugin's registration or handler fails that
  plugin, not the run; one thrown through Swift code cannot be caught.
  `shared_preferences_foundation` stays the runner's own, above. On an
  M1 Pro: `url_launcher` built in 12 s cold, 0.2 s from the cache; the
  fifteen of `tool/plugins` in 2 min cold, all loaded; `firebase_core`
  and its pods in 47 s cold, and `Firebase.initializeApp` answers.
  Loading FlutterMacOS adds about 17 MB of resident memory and no
  measurable time to the first frame (184 to 188 ms, median of five); the
  run loop costs nothing at idle. The Objective-C runtime notes, once per
  run, the classes FlutterMacOS and the engine library both carry. FFI
  plugins (`ffiPlugin: true`) are built the same way and have no class:
  the runner opens their frameworks to the whole process, and `run` puts
  them on `DYLD_FRAMEWORK_PATH`, so Dart finds their symbols whether it
  looks in the process (`DynamicLibrary.process()`, as `flutter_pty2`
  does) or opens `<name>.framework/<name>`.
- Builds native assets (packages with build hooks, such as `objective_c`
  under `path_provider_foundation`) for macOS. The tool builds the bundle
  for the Linux device it believes Raccoon to be, whose manifest names no
  code assets for a Mac; `tool/raccoon-device install` runs the tool's
  macOS bundle target for this machine (`flutter assemble ...
  debug_macos_bundle_flutter_assets`, no `macos/` directory needed), puts
  the code assets beside the app and names them by absolute path in the
  installed `NativeAssetsManifest.json`, under the host's key. Only for
  projects with hook packages: on an M1 Pro, 9 s the first time for a new
  project, about a second after. Such an app runs in its own bundle too, so
  `path_provider` names its directories after it
  (`~/Library/Application Support/dev.raccoon.app.<app>`). On Linux the
  hooks are not built yet.
- Never leaves the app waiting on a plugin nobody serves. A channel no one
  answers gets an empty reply, which the app sees as
  `MissingPluginException` (Pigeon's `channel-error`), as on a desktop the
  plugin does not support; the first time a channel goes unanswered, for
  each reason, stderr says `raccoon_runner: nothing answered CHANNEL
  (WHY); the app sees no plugin`. The engine's own `flutter/` channels are
  left out: a null reply there is normal. A message the client takes and
  does not answer within 5 seconds gets the same empty reply. No plugin is
  faked: a made-up success would break Pigeon plugins worse.
- `serve` relays the app's log to the client as `LogLine` messages: the
  engine's lines, and stderr, where the engine prints what `main()` died of
  (`Unhandled Exception: ...`). Stderr passes through a pipe the runner
  reads, still copied to the real one as it comes, and drained on a crash.
  The lines from before the first frame, the last 200, go again to a
  client that arrives later, so a host can show why an app stopped before
  it drew anything (`StartupFailure` in `raccoon_runtime`).
  `example/no_plugin` dies in `main()` of a call nobody serves;
  `example/no_plugin_late` makes the same call after its first frame and
  goes on.
- `render`: writes one frame to a PPM file, for tests and a quick look.
- `tool/raccoon-device`: ping, install, uninstall and run for the Flutter
  tool's custom device, so a stock `flutter run -d raccoon` works.
  `--instance KEY` names everything `<app>@KEY`, which is how the
  `raccoon-2`, `raccoon-phone`, `raccoon-tablet` and `raccoon-desktop`
  devices keep their runs of the same project apart; `--size 820x1180@2`
  starts the runner at a device's logical size and pixel ratio; each run's
  output lands timestamped in the app's data directory as `runner.log`. A
  runner that ends badly is said so in the run's output: `raccoon-device:
  raccoon_runner exited with code N`, or `died of signal SEGV (11)`.

## Build

Linux needs a C++17 compiler, CMake and Ninja; macOS the Xcode command-line
tools plus `brew install cmake ninja`; Windows Visual Studio's C++ workload
(MSVC, with its own CMake and Ninja) and Git Bash, from which the commands
below run once the MSVC environment is loaded (`vcvars64.bat`).

```sh
tool/protoc.sh                       # user-local protoc 21.12, once
cmake -S . -B build -G Ninja -DRACCOON_ENGINE_DIR="$(tool/engine_dir.sh)"
ninja -C build                       # first build also compiles protobuf-lite
```

CI (`.github/workflows/runner-ci.yml`) does the same on Linux x64, both Mac
architectures and Windows x64, bundles the examples, renders a frame, and
runs `raccoon_runtime`'s tests, whose integration tests drive the built
runner.

## Prebuilt binaries

Every tag `v<VERSION>` publishes `raccoon_runner-<version>-<platform>.tar.gz`
for `linux-x64`, `macos-arm64`, `macos-x64` and `windows-x64` (with
`raccoon_runner.exe`; its helper runs in Git Bash) on the [releases
page](https://github.com/SoFluffyOS/raccoon/releases), under `runner-v*` tags, packed by
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
`$TMPDIR/raccoon`, which is where `tool/raccoon-device` puts them; on
Windows under `engine/windows-x64` and in `%TEMP%\raccoon`.

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
and run `packages/raccoon/tool/gen_proto.sh` for the Dart side. Bump
`RaccoonProtocol.version` on incompatible changes.

## Hosts

Linux, macOS and Windows, from the same sources; the per-host seams are the
wake descriptor (eventfd, a pipe, or a pair of sockets for Windows'
`WSAPoll`), socket flags, the shared buffers' backing (a memfd, or an
unlinked temporary file on macOS, whose POSIX shared memory cannot be read
with `read()`; none on Windows, where no handle crosses a socket), the GPU
renderer (EGL and dmabufs, or Metal and IOSurfaces), the engine library's
name, the pixel order, how the runner notices its parent is gone, and the
native plugins' object model and main loop (GObject and GLib, or
FlutterMacOS and the main run loop).

Windows has the software renderer and inline frames; GPU frames
([#25](https://github.com/SoFluffyOS/raccoon/issues/25)) and native plugins
([#36](https://github.com/SoFluffyOS/raccoon/issues/36)) come later. The
custom device starts the helper with Git for Windows' `bash.exe`, and the
runner stops when any process from its parent up through Git Bash to the
tool ends. Measured on a Ryzen 9 7945HX: `flutter run -d raccoon` in
example/hello reaches the VM service 4.4 s after Launching, hot reload
takes 71 ms; example/spin draws at 58 fps in a 1200x800 pane (runner 29%,
client 47% of a core) and 56 fps at 2400x1600 (99%, 130%), where copying
inline frames is the cost.

## Issues

Report here: [SoFluffyOS/raccoon](https://github.com/SoFluffyOS/raccoon/issues). One tracker for every Raccoon repository, whichever piece the bug is in. Issues are off on this one.

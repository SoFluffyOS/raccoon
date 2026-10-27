# raccoon_runner

[![CI](https://github.com/SoFluffyOS/raccoon/actions/workflows/runner-ci.yml/badge.svg)](https://github.com/SoFluffyOS/raccoon/actions/workflows/runner-ci.yml)

The Raccoon runtime's runner: hosts a Flutter app on the C embedder API, for
Lumide. Part of the [raccoon](https://github.com/SoFluffyOS/raccoon) repository at `native/raccoon_runner`; Lumide and the simulator take that repository as a git submodule.

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
  shutdown. A frame with a side over 8,192 pixels is scaled down to fit,
  its pixel ratio with it: the app keeps its logical size (#117).
  The app sees `RACCOON_ENDPOINT=unix:<socket>`, which `package:raccoon`'s
  `Raccoon().isPresent` reads (#150).
- Views mode (`--views`, or `RACCOON_VIEWS=1` through the Flutter tool)
  shows one app in several views, each with its own size and pixel ratio,
  all from one engine, so one hot reload updates them all (#182).
  - The engine draws through a compositor. Each view has a target of its
    own beside the renderer: a Metal or GL ring and readback, or a buffer
    in software. Vulkan has no such target yet, so views mode on Windows
    rasterizes in software.
  - Clients:
    - The first client keeps the runner's socket and shows view 0.
    - Each connection to `<socket>.views` (`.views` in place of `.sock`) is a
      view of its own. It is added at the client's first resize and removed
      when the client hangs up.
    - A view's client speaks the same protocol. It gets frames inline, through
      shared buffers, or as GPU buffers served on `<socket>.v<N>.gpu`, and its
      pointer events go to its view.
    - Keys and text go to the app. The text field follows the client the user
      last pressed in. Platform messages, logs and plugins stay with the
      first client.
    - `RunnerHello.views` says whether a runner takes views.
  - `runApp` draws into the first view only. The app needs a binding that lays
    its root out in every view; `example/views` has one.
  - `render --view WxH@DPR` adds views and writes each beside `--out` as
    `NAME.view<N>.ppm`.
- Answers some plugins' channels itself, in both commands and with or
  without a client, because apps call them at startup (Wonderous before its
  first frame) and an unanswered call throws:
  - the window plugins (`desktop_window`, `window_manager`, `window_size`):
    the app's window is the client's pane, so sizes come from the view and
    requests to resize, move or go full screen are recorded, not applied;
  - `screen_retriever`: the pane is the one display, at the view's logical
    size and pixel ratio, on 0.2's channel and 0.1's (#156);
  - `shared_preferences_foundation`, which a Mac host's Dart VM picks (it
    reports macOS), kept in `--data-dir` when given (`tool/raccoon-device`
    passes one per app), in memory otherwise.
  On Linux the app's Dart VM picks the Dart-only `path_provider_linux` and
  `shared_preferences_linux`, which name their directories after the
  executable: with `--data-dir` the runner points `XDG_DATA_HOME` and
  `XDG_CACHE_HOME` into it, so apps do not share one.
  `example/channels` checks the answers.
- Answers the `camera` plugin from a test pattern: `camera` ships no desktop
  implementation, so the app falls back to its method channel one. There are
  two cameras, back and front; the resolution preset picks the size, up to
  1920×1080. Colour bars cover the top three quarters, and a white block moves
  along the bottom quarter. `--camera-source` or `RACCOON_CAMERA_SOURCE` names
  a PNG or JPEG to show instead. It is decoded once with the vendored
  stb_image (`third_party/stb`), scaled to cover the camera's size and cropped
  to its centre. On Windows the source can also be a video, such as an MP4.
  Media Foundation decodes it a frame at a time as each comes due, and it
  plays in a loop. Other hosts refuse a video for now. A file that doesn't
  decode is reported, and the pattern stays. The variable works from a
  terminal too: `RACCOON_CAMERA_SOURCE=qr.png flutter run -d raccoon`.
  `takePicture` writes the current frame as a JPEG to the temp directory.
  Image streams run at up to 30 fps, as I420 (`yuv420`), BGRA (`bgra8888`, the
  default) or JPEG. On Windows, video recordings encode what the camera shows
  to an H.264 MP4 with Media Foundation, at the camera's size and fps. Pause
  and resume leave the paused time out, and `enableStream` streams while
  recording. Other hosts refuse to record for now. The preview is a `Texture`
  by camera id, filled at the camera's frame rate through the GL or Metal
  renderer's external textures. It is the camera's size turned to portrait
  (288×352 for `low`), because `CameraPreview` draws a portrait box while the
  device is portrait up. `pausePreview` stops it, and while nothing draws the
  texture it drops to a probe four times a second, so a camera nobody shows
  keeps no app drawing. Camera ids start at 2^48 + 1, so they stay clear of
  plugins' textures. The software and Vulkan renderers take no external
  textures, so the preview is blank there, which includes Windows.
  `CameraController`'s `startImageStream` asserts in a debug build, because
  the method channel implementation reports no streaming.
  `CameraPlatform.instance. onStreamedFrameAvailable` streams without that
  check. `example/camera` takes a picture and streams each format: 352×288
  frames at 30.0 fps, each format's colours checked. It then records 600 ms,
  pauses for 400 ms and records 400 ms more, which gives 31 frames and 1033 ms
  of video.
- Tells the app the host's locales and appearance after the engine starts,
  as a desktop embedding does: on macOS the preferred languages, light or
  dark, and the locale's 12- or 24-hour clock; on Linux the locales of
  `LANGUAGE`, `LC_ALL`, `LC_MESSAGES` and `LANG`. Without it an app saw no
  locales and a light host. It also says the app is resumed
  (`flutter/lifecycle`), as desktop embeddings do once the engine runs;
  before, `lifecycleState` stayed null. A client shows the app as a device
  rather than the host: its `Settings` replace the locales, text scale
  (otherwise 1), dark mode and hour format it sets, and `Resize.view_inset_*`
  is what covers the view's edges, an on-screen keyboard, as the app's
  `viewInsets` (#193). An `AppMessage` goes to the app as a platform
  message, as a device's own controls send one: the background and back
  (`flutter/lifecycle`), a link opened or the back button pressed
  (`flutter/navigation`) (#199, #209).
- Delivers keys the way the framework expects: the key data, then the
  legacy `flutter/keyevent` message it waits for before dispatching. Without
  the second, no key ever reaches the app.
- Types: it answers `flutter/textinput` and keeps the active field's editing
  state, so the keys the framework leaves unhandled insert text, delete,
  move and act; `example/text` shows it. On a Mac they go back as the
  selectors AppKit's key bindings name (`deleteWordBackward:`,
  `moveToLeftEndOfLine:`, ...), as a Mac app's framework expects. Enter
  inserts a newline only in a multiline field whose action is newline, and
  always sends the action. A client with an input method says so in its
  hello (`composes`), mirrors the field and types through it (#151).
- Rasterizes on the GPU where the host offers one without a window: through
  EGL on Linux (Mesa: the surfaceless platform or a render node), through
  Metal on macOS, through Vulkan on Windows. By default each frame is read back as pixels in the
  host's order, so clients see the same frames as from the software
  renderer; at 2400×1600 that halves the runner's CPU. A client that asks
  for `gpu_buffers` gets a ring of four textures instead, exported as DRM
  dmabufs on Linux, backed by IOSurfaces on macOS and shared D3D11
  textures on Windows: the engine draws
  straight into them and a frame is the index of its buffer, no pixels. The
  ring is described over a second socket, the main one's path with `.gpu`
  in place of `.sock` (its layout is in `main.cc`). On Linux the
  descriptors ride along, and a native fence goes ahead of every frame
  where EGL has them. On macOS a client that asks ('RPRT') gets the name of
  a Mach service of the runner's own and a token, and takes each ring's
  surfaces from it by port. The runner announces the ring in use once more,
  the client asks for it, and once an ask has reached the service the rings
  are not global, so no other process can open them by ID. A client that
  never asks, or whose lookup of the service fails, keeps global surfaces
  named by ID, and so does the next client once it has gone. A frame leaves once the GPU has drawn it:
  a cross-process fence would save 0.6-0.8 ms at the median (measured, #60),
  and Metal shares none without XPC. A buffer goes back on either
  socket, with a fence of its own on the second where there are fences. The
  raccoon_view plugin does this on Linux, macOS and Windows. `--renderer
  auto|gl|metal|vulkan|software`, or `RACCOON_RENDERER` in the environment: `auto`
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
  `screen_retriever` and its `_macos`, `_linux` and `_windows` halves)
  stay the runner's own, above. `example/plugins/echo`
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
  A plugin with a Swift package (`macos/<name>/Package.swift`, or under
  `darwin/`) builds through it instead, as Flutter builds it (#187). All
  of an app's Swift packages go into one framework, `RaccoonPlugins`, so
  what they share (FirebaseCore) is loaded once. The helper lays the
  packages out as Flutter does (each plugin by its name beside an empty
  `FlutterFramework` package) and builds a package of its own, a dynamic
  library depending on every plugin's product, with `xcodebuild`. Needs
  Xcode only. It is cached by the plugins' keys together and kept failed
  like a pod. The plugins its errors name (a package that does not
  resolve, a source that does not compile) are left out and the rest built
  again, as for pods (#191). Two that pin versions of a third no one
  version gives (FlutterFire 13 and Google Sign-In 9, through
  `gtm-session-fetcher`): the side with fewer plugins tied to it by their
  pubspecs goes (#192). A plugin left out is kept out while the app's set
  of Swift packages stays the same, and tried again when it changes, the
  other side of a conflict gone, say (#203). A plugin goes with those it is tied to, so a family
  never loads its SDK twice, half package and half pod. What the two sides
  share below that loads twice (Google Sign-In's pod links its own
  `GTMSessionFetcher` 3 and `GoogleUtilities`: 25 classes "implemented in
  both", which the runner says in one line for each two libraries, #198);
  each library calls its own copy.
  Flutter's own build refuses the pair. When it fails otherwise, the plugins that
  have a podspec too go through CocoaPods. When every one of them is a pod in the cache already
  (the release's prebuilt plugins), those load instead of a build. `RACCOON_NO_SWIFT_PACKAGES=1` builds them all through
  CocoaPods. On an M1 Pro: FlutterFire's core, Auth, Firestore and
  Analytics in 89 s cold into one 33 MB framework (13 min and 266 MB
  through CocoaPods, whose trunk lacks the Analytics SDK they pin), and
  0.1 s from the cache.
  `run` starts the runner of an app with plugins through a bundle of the
  app's own (`<app>.app`, identifier `dev.raccoon.app.<app>`, a symlink to
  the runner), because some of Apple's APIs throw without one. While
  plugins are loaded the runner waits in the main run loop instead of
  poll(2), so the main queue, timers and AppKit's events run (it starts as
  an accessory application, no Dock icon); a plugin's textures, BGRA or
  bi-planar YUV pixel buffers, draw through the Metal renderer. An
  Objective-C exception from a plugin's registration or handler fails that
  plugin, not the run; one thrown through Swift code cannot be caught.
  `shared_preferences_foundation` stays the runner's own, above.
  `flutter_secure_storage` gets the login keychain: the runner drops the
  options an unsigned process can't have (the data protection keychain,
  an access group, iCloud sync) on the way to it. On an
  M1 Pro: `url_launcher` built in 12 s cold, 0.2 s from the cache; the
  fifteen of `tool/plugins` in 2 min cold, all loaded; `firebase_core`
  and its pods in 47 s cold, and `Firebase.initializeApp` answers.
  A plugin that fails to build is kept failed, its log beside it in the
  cache, so the next install skips it instead of spending its pod install
  and build again. It is kept for a day, by the same key a build would have
  and by the Xcode and CocoaPods versions (CMake and the compiler on
  Linux, which keeps failures the same way), so a new version of the plugin,
  an edit to a path plugin, a new runner or a new toolchain tries again.
  `RACCOON_RETRY_PLUGINS=1` tries again at once (#136).
  `RACCOON_PLUGINS` says how much of this an install does, on every host:
  `build` (the default) as above; `cached` takes the cache and the
  release's prebuilt plugins but compiles nothing, and a client is told
  what it left out, as skipped; `off` has no native plugins at all
  (`RACCOON_PLUGINS=off flutter run -d raccoon`). The app's calls to a
  plugin it lacks fail as for a plugin with no implementation. Unset, the
  app's own setting says (`<data>/<app>/plugins`), else the host's default
  (`<data>/.plugins`), both as raccoon_runtime's `AppPlugins` saves them;
  build otherwise (#214). Native assets (build hooks) build either way.
  Loading FlutterMacOS adds about 17 MB of resident memory and no
  measurable time to the first frame (184 to 188 ms, median of five); the
  run loop costs nothing at idle. The Objective-C runtime notes, once per
  run, the classes FlutterMacOS and the engine library both carry. FFI
  plugins (`ffiPlugin: true`) are built the same way and have no class:
  the runner opens their frameworks to the whole process, and `run` puts
  them on `DYLD_FRAMEWORK_PATH`, so Dart finds their symbols whether it
  looks in the process (`DynamicLibrary.process()`, as `flutter_pty2`
  does) or opens `<name>.framework/<name>`.
- Loads the project's native plugins on Windows as well. A plugin DLL
  imports the C API of Flutter's Windows embedding from
  `flutter_windows.dll` (through the C++ client wrapper compiled into it);
  the runner ships a DLL of that name beside itself, built from the public
  headers alone (`third_party/flutter_windows`), and opens it before any
  plugin, so their imports land on it and the engine behind it is this
  runner: the messenger, a registrar per plugin, a view that is a hidden
  top-level window (a real `HWND` to parent dialogs to, whose messages
  reach the plugins' window proc delegates), no textures yet. The manifest
  names each DLL and its `<PluginClass>RegisterWithRegistrar`.
  `tool/raccoon-device install` builds the plugins the project resolves
  (every package with a Windows `pluginClass` or `ffiPlugin`) each in its
  own CMake project with what Flutter's Windows template gives a plugin,
  against the SDK's import library and C++ client wrapper, with Visual
  Studio's own generator, as the Flutter tool builds a Windows app; that
  half of the helper is `tool/plugins_windows.dart`, run with the SDK's
  `dart`, since Windows has no python3. Needs Visual Studio with the C++
  workload, as the Windows target does; cached as on the other hosts.
  While plugins are loaded the runner waits in `MsgWaitForMultipleObjectsEx`
  and dispatches the platform thread's messages, so dialogs, COM and
  messages posted to windows work; a modal dialog's own loop holds the
  runner's while it is open. FFI plugins' DLLs go on the runner's PATH.
  The runner carries a version resource, which `package_info_plus` reads.
  On a Ryzen 9 7945HX: the eleven of `tool/plugins` with Windows code in
  88 s cold, 2 s from the cache, all loaded; `connectivity_plus`,
  `url_launcher` and `flutter_secure_storage` answer from the runner.
- Builds native assets (packages with build hooks, such as `objective_c`
  under `path_provider_foundation`) for macOS. The tool builds the bundle
  for the Linux device it believes Raccoon to be, whose manifest names no
  code assets for a Mac; `tool/raccoon-device install` runs the tool's
  macOS bundle target for this machine (`flutter assemble ...
  debug_macos_bundle_flutter_assets`, no `macos/` directory needed), puts
  the code assets beside the app and names them by absolute path in the
  installed `NativeAssetsManifest.json`, under the host's key. Only for
  projects with hook packages: on an M1 Pro, 9 s the first time for a new
  project, about 1.7 s after any change. While nothing changes, the next
  install reuses that build: the inputs are the package config, the
  pubspecs, the SDK's engine, the target, and the files of each hook
  package and of the local packages it depends on, so a hook or a header
  edited in a path dependency builds again. Such an app runs in its own bundle too, so
  `path_provider` names its directories after it
  (`~/Library/Application Support/dev.raccoon.app.<app>`). On Linux the same
  with the Linux bundle target (`debug_bundle_linux-x64_assets`); it unpacks
  the GTK engine into `linux/flutter/ephemeral`, and the helper takes away
  a `linux/` that holds nothing else, so a project without a Linux app gets
  none, even after an install cut short. `example/native_assets_app`
  calls a C function from a hook (`example/native_add`) and prints
  `NATIVE:42`.
- Never leaves the app waiting on a plugin nobody serves. A channel no one
  answers gets an empty reply, which the app sees as
  `MissingPluginException` (Pigeon's `channel-error`), as on a desktop the
  plugin does not support; the first time a channel goes unanswered, for
  each reason, stderr says `🦝 nothing answered CHANNEL (WHY); the app
  sees no plugin`. The engine's own `flutter/` channels are
  left out: a null reply there is normal. A message the client takes and
  does not answer within 5 seconds gets the same empty reply. One sent
  before any client has come waits up to 1 second for the first, which an
  IDE polling for runners may be later than an app's first call in
  `main()` (#196). The runner fakes no plugin: a made-up success would
  break Pigeon plugins worse. The answers a phone gives come from the
  client, typed per plugin (`PluginStubs` in `raccoon_view`, #195).
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
- Never lets a client hold up the app. What goes to the client queues,
  written as far as its socket takes it, the rest when it can take more;
  frames wait while anything is queued, the newest replacing the rest. A
  client paused in a debugger keeps its place for as long as it likes; one
  that leaves more than 16 MB unread behind the message being written is
  let go. A client that says hello again without shared buffers gets
  frames inline from then on.
- `render`: writes one frame to a PPM file, for tests and a quick look.
- `tool/raccoon-device`: ping, install, uninstall and run for the Flutter
  tool's custom device, so a stock `flutter run -d raccoon` works.
  `--instance KEY` names everything `<app>@KEY`, which is how the
  `raccoon-2`, `raccoon-phone`, `raccoon-tablet` and `raccoon-desktop`
  devices keep their runs of the same project apart; `--size 820x1180@2`
  starts the runner at a device's logical size and pixel ratio, and without
  it the run starts at the size a host's board last gave the app
  (`<data>/raccoon/data/<app>/size`, raccoon_runtime's `AppSizes`); each run's
  output lands timestamped in the app's data directory as `runner.log`. A
  runner that ends badly is said so in the run's output: `🦝 raccoon_runner
  exited with code N`, or `🦝 raccoon_runner died of signal SEGV (11)`. So is
  a run that can't start: an app not installed, no runner binary, or an
  engine that can't be downloaded (#119). Each run's socket is
  `<socket dir>/<app>.sock`; a key too long for a socket path (104 bytes
  on macOS) gets as much of it as fits and `~<checksum>`, with the key in
  a `.name` file beside the socket, which `RunnerDiscovery` reads (#118).

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

Without `-DCMAKE_BUILD_TYPE` the build is RelWithDebInfo: optimised, with
symbols. Unoptimised, the pixel path costs about four times the CPU (#159).

CI (`.github/workflows/runner-ci.yml`) does the same on Linux x64, both Mac
architectures and Windows x64, bundles the examples, renders a frame, and
runs `raccoon_runtime`'s tests, whose integration tests drive the built
runner. It runs when started by hand, from the Actions tab or with
`gh workflow run runner-ci.yml --ref main`, not on every push.

## Prebuilt binaries

Every tag `runner-v<VERSION>` publishes
`raccoon_runner-<version>-<platform>.tar.gz` for `linux-x64`, `macos-arm64`,
`macos-x64` and `windows-x64` (with `raccoon_runner.exe`; its helper runs in
Git Bash) on the [releases
page](https://github.com/SoFluffyOS/raccoon/releases), packed by
`tool/package.sh`: the binary, `tool/raccoon-device` with `engine_dir.sh`,
`package_scope.dart` and `plugins_windows.dart`, `VERSION` and `LICENSE`,
with the prebuilt common plugins beside them for Linux and macOS. The Mac
binaries run on macOS 12 and later, as the engine does; the Linux ones are
built on Ubuntu 22.04, for its glibc and later. Unpacked into a folder it works as a runtime
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
`runner-v$(cat VERSION)`: `.github/workflows/runner-release.yml` refuses a tag
that does not match. Plain `v*` tags are the `raccoon` package's. Run by
hand, the workflow builds and keeps the archives as artifacts without
publishing them.

## Try it

```sh
tool/render_example.sh               # build/frame.png of example/hello
```

Serve the example and look at it from `packages/raccoon_view/example`,
run with `--dart-define=RACCOON_SOCKET=<the socket>` (it looks for
`raccoon/runner.sock` otherwise):

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
HELPER="$PWD/tool/raccoon-device"
(cd ../../packages/raccoon_runtime && dart run raccoon_runtime:raccoon_device setup --helper "$HELPER")
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
renderer (EGL and dmabufs, Metal and IOSurfaces, or Vulkan and D3D11
textures), the engine library's
name, the pixel order, how the runner notices its parent is gone, and the
native plugins' object model and main loop (GObject and GLib, or
FlutterMacOS and the main run loop).

Windows has no shared memory across a socket, so pixel frames come inline;
GPU frames go through the Vulkan renderer's shared D3D11 textures, and
native plugins load as above. Those textures are shared the legacy way
(`D3D11_RESOURCE_MISC_SHARED`), the only kind Flutter's texture registrar
takes on the client's side: such a handle has no access list, so another
process of the same user that guesses it can read the frames (#126). A
client that would rather not takes pixel frames. The custom device starts the helper with Git for Windows' `bash.exe`, and the
runner stops when any process from its parent up through Git Bash to the
tool ends. Measured on a Ryzen 9 7945HX: `flutter run -d raccoon` in
example/hello reaches the VM service 4.4 s after Launching, hot reload
takes 71 ms; example/spin draws at 58 fps in a 1200x800 pane (runner 29%,
client 47% of a core) and 56 fps at 2400x1600 (99%, 130%), where copying
inline frames is the cost.

## Issues

Report here: [SoFluffyOS/raccoon](https://github.com/SoFluffyOS/raccoon/issues). One tracker for every piece of Raccoon, whichever the bug is in.

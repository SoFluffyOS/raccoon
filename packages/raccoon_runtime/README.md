# raccoon_runtime

The host side of the Raccoon runtime, as Lumide uses it: the
runtime store, runner process management and discovery, the custom-device
configuration, and the frame and input client. Pure Dart, no Flutter, so
servers and command-line tools can share it.

Connect with `gpuBuffers: true` (`RunnerClient.connect`) and a runner that
rasterizes on the GPU describes its ring in `GpuBuffers`, then sends frames
as buffer indices, no pixels; `releaseGpuBuffer` gives one back. What
imports the buffers rides a second socket for a native host side: file
descriptors on Linux, which Dart cannot hold, IOSurfaces by Mach port (or
ID) on macOS, and D3D11 shared handles on Windows. `raccoon_view` has the
host sides. A frame the runner cannot put in a buffer still comes with
pixels. A GPU buffer frame has none, so a capture (a screenshot, a GIF)
calls `wantPixels(true)` for read-back pixel frames while it takes them,
and `wantPixels(false)` after; the view goes on showing its ring.

Pixel frames come through shared memory where the socket carries file
descriptors (Linux and macOS), and the client reads each into a new buffer.
With `reusePixels: true` it reads them into three buffers it keeps instead:
about a quarter of a core less at a phone's size and 60 fps, but a frame's
pixels then hold only until the third frame after it, so a consumer that
keeps them longer copies them. `raccoon_view` copies what it shows. With
nobody listening to the frames (a host that disposed a hidden view), the
latest stays unread in its shared buffer until `latestFrame` asks for it,
so a hidden app costs the client next to nothing.

An app that stops before its first frame, such as one whose `main()` awaits
a plugin with no implementation on this host, shows up as
`RunnerClient.startupFailure`: the exception it died of and the channels
nothing answered, read from the log the runner relays, with the plugin
each channel belongs to when the plugin report says it cannot work here.
It waits a moment for a frame (`startupGrace`), and once a frame arrives it
stays null: from then on the app's own error handling rules.

A host shows the app as a device rather than itself.
`RunnerClient.sendSettings` replaces the host's locales, text scale, dark
mode and hour format, and `setViewInsets` covers the view's bottom with an
on-screen keyboard, as the app's `viewInsets`. The engine has no way to say
a safe area or a target platform. A run started from the entry
`RaccoonEntrypoint.write` generates gets both: the entry asks the client,
and `DeviceChannel` answers per view with a `DeviceProfile` (its padding
and a `TargetPlatform` name). Calls the app makes before any client
connects wait up to a second for the first, so a client that registers its
channels as soon as it connects, before the hello, answers them.

`raccoon_device setup` registers one device with the Flutter tool,
`raccoon`. The size belongs to the run, not the device: a host's board
picks it (Phone, Tablet, Desktop, or the frame dragged to any size), the
app resizes live, and `AppSizes` keeps it so the next run starts there.

More devices are only for running copies side by side, since the Flutter
tool runs a project once per device. `raccoon_device add
phone|tablet|desktop|<name>` adds one, each a custom device the helper keeps
apart by an instance key (`RaccoonDevice`): `raccoon-2` (a second run of the
same project), and the sized ones that start at their logical size and pixel
ratio, `raccoon-phone` (390×844 @3x), `raccoon-tablet` (820×1180 @2x) and
`raccoon-desktop` (1280×800 @1x). `raccoon_device remove <name>` takes one
away.

A machine with no checkout is set up from a release: `RunnerDownloader`
finds the newest `runner-v*` release that goes with `RunnerVersion.current`
and unpacks it into a `PrebuiltRunner`'s folder, whose `deviceHelper` the
`raccoon` entry then names (`CustomDevicesFile.upsert`). The archive is
checked against the SHA-256 the release lists and its own gzip trailer,
each install unpacks apart, so two hosts setting up at once don't mix
their files, and a runner counts as installed only with its device helper; `RuntimeStore`
fetches the engine for the SDK, and `FlutterSettings` says whether the tool
lists custom devices at all (`flutter config --enable-custom-devices`).
Both of the tool's files are found where the tool itself keeps them
(`flutterConfigPath`).

What an install does with an app's native plugins (`RACCOON_PLUGINS`:
build them, take only what is cached, or none) is saved per app, or as the
host's default for apps with no setting of their own, with `AppPlugins`.

The same holds on Linux, macOS and Windows. On every host the runner is
reached through a Unix socket in the host's socket folder, which
`RunnerDiscovery` watches: `$XDG_RUNTIME_DIR/raccoon` on Linux (else
`$TMPDIR/raccoon`, then `/tmp/raccoon`), `$TMPDIR/raccoon` on macOS. Where
that folder sits in one others may write to, as `/tmp` is, the device
helper keeps it the user's alone and refuses a link there, and
`RunnerDiscovery.isOwn` takes it only when it is the user's own and nobody
else may write to it. On Windows it is `%TEMP%\raccoon`, where dart:io
speaks AF_UNIX too but no handles cross, so pixel frames come inline. There the
Flutter tool keeps its devices in `%APPDATA%\.flutter_custom_devices.json`,
and each command starts the helper with Git for Windows' `bash.exe`.

## Testing on Raccoon devices

A Raccoon device needs no emulator, no native build and no display. On
Linux the runner renders headless, through EGL's surfaceless platform or in
software, and the app's VM service answers with nobody attached.
`example/hello` on `raccoon-phone`, on a Linux workstation:

- `flutter test integration_test -d raccoon-phone`: first result 6.6 s from
  nothing built, 1.9 s warm.
- `flutter drive -d raccoon-phone`: 3.4 s warm.
- `RaccoonTestDevice.launch`: 1.3 s warm. A tap to the frame that shows it
  340 ms, hot reload 360 ms, hot restart 640 ms.
- `RaccoonTestDevice.launchAll` on the phone, the tablet and the desktop:
  3.0 s warm against 1.3 s for one, 6.7 s cold.

Set the devices up once, from a checkout's helper or from a release:

```sh
flutter config --enable-custom-devices
helper="$(dart run raccoon_runtime:raccoon_device fetch --into ~/raccoon_runner)"
dart run raccoon_runtime:raccoon_device setup --helper "$helper"
for d in phone tablet desktop; do dart run raccoon_runtime:raccoon_device add $d; done
```

`RACCOON_HEADLESS=1` tells the runner no host is coming: what the app asks
of a host's plugins before one connects gets "no plugin" at once, not after
a second's wait. Frames and the VM service go on either way.

Flutter's own tests run as they are, the custom device needs nothing more:

```sh
RACCOON_HEADLESS=1 flutter test integration_test -d raccoon-phone
RACCOON_HEADLESS=1 flutter drive -d raccoon-phone \
  --driver test_driver/integration_test.dart \
  --target integration_test/app_test.dart
```

Two things don't, the same as on a Linux desktop or worse:
`IntegrationTestWidgetsFlutterBinding.takeScreenshot` asks the
integration_test plugin's native side, which only Android and iOS have, and
`flutter screenshot -d raccoon-phone` wants a `screenshot` command the
device entry does not have. `FlutterDriver.screenshot` works, through the
engine.

From plain `dart test`, `RaccoonTestDevice` runs a project the way the
simulator and Lumide do, `flutter run -d <device> --machine`, and attaches
to its runner as a host would. Input is in logical pixels, frames come
decoded and as PNGs once the app settles:

```dart
final phone = await RaccoonTestDevice.launch('path/to/app');
await phone.tap(195, 422);                  // logical pixels
final frame = await phone.frame();          // after the app settles
expect(frame.colorAt(195, 422), 0xFF43A047);
await frame.expectGolden('goldens/phone.png', maxDifferingRatio: 0.001);
await phone.hotReload();
await phone.stop();
```

- `launch(project, device:, target:, size:, gpuBuffers:)`, or
  `launchBundle(assets, ...)` to start the runner on a built bundle, no
  Flutter tool and so no hot reload. `launchAll(project)` starts the
  phone, the tablet and the desktop and returns the three; the first
  builds, the others start on its build.
- `tap`, `longPress`, `drag`, `scroll` (a mouse wheel), `typeText` into the
  focused field, `pressKey(RaccoonKey.enter)`.
- `frame()`: a `RaccoonFrame`, with `image` (package:image), `png()`,
  `colorAt` in logical pixels, `compareToGolden` and `expectGolden`. A golden
  that is missing is written, `RACCOON_UPDATE_GOLDENS=1` writes them all
  again, and a mismatch leaves `<name>.actual.png` beside the golden.
- `logs` and `logLines`: the app's output and the runner's `🦝` lines.
- `vmServiceUri` and `vmServiceWebSocketUri`, `hotReload`, `hotRestart`,
  `stop`. `client` is the `RunnerClient` for the rest: semantics, settings,
  the lifecycle.
- `gpuBuffers: true` takes frames in a GPU ring as the hosts do and reads
  pixels back only for `frame()`.

`native/raccoon_runner/example/harness_test` is the example: hello on the
phone (a tap, its pixels, a golden, hot reload and restart), and its layout
on the three devices at once. Text is drawn in a fallback font the machine
has, so its goldens allow 2 % of pixels to differ.

### In CI

`.github/workflows/device-tests.yml` in this repository is the recipe: one
`ubuntu-latest` job, no display, no runner build. It takes 2 min, Flutter's
setup included. Mesa draws through llvmpipe there: the integration test
step takes 14 s from nothing built, `flutter drive` on the tablet 13 s,
`RaccoonTestDevice` launches the phone in 6.4 s cold, and hello's goldens
from a workstation's GPU differ from it in 0.6 % of their pixels, the text's
edges.

```yaml
- uses: subosito/flutter-action@v2
  with: {channel: stable, flutter-version: 3.50.0}
- run: sudo apt-get update && sudo apt-get install -y libegl1 libegl-mesa0 libgles2
- run: flutter precache --linux          # the ICU data the runner takes
- run: |
    helper="$(dart run raccoon_runtime:raccoon_device fetch --into "$RUNNER_TEMP/raccoon_runner")"
    dart run raccoon_runtime:raccoon_device setup --helper "$helper"
    for d in phone tablet desktop; do dart run raccoon_runtime:raccoon_device add $d; done
    flutter config --enable-custom-devices
- run: RACCOON_HEADLESS=1 flutter test integration_test -d raccoon-phone
- run: dart test                         # RaccoonTestDevice tests
```

`fetch` takes the newest `runner-v*` release that goes with the runtime.
`raccoon_runtime` is not on pub.dev: run these in a checkout's
`packages/raccoon_runtime`, or in a project that takes it as a git
dependency (`path: packages/raccoon_runtime`). Give each test step a
`timeout-minutes`: a runner that dies before its VM service is up (it needs
`libEGL.so.1`) leaves `flutter test` and `flutter drive` waiting for good.
`RaccoonTestDevice.launch` fails at once instead.

### For coding agents: marionette_mcp

[marionette_mcp](https://pub.dev/packages/marionette_mcp) lets an agent
inspect and drive a running Flutter app over its VM service. On a Raccoon
device it works as it is. Add `marionette_flutter` to the app and call
`MarionetteBinding.ensureInitialized()` before `runApp`, run it, and hand
the agent the VM service:

```sh
dart pub global activate marionette_mcp
claude mcp add --transport stdio marionette -- marionette_mcp   # or your agent's own
RACCOON_HEADLESS=1 flutter run -d raccoon-phone                 # prints ws://127.0.0.1:<port>/<token>/ws
```

The agent calls `connect` with that URI. `RaccoonTestDevice` has it as
`vmServiceWebSocketUri`. Measured with marionette_mcp 0.7.0 on
`raccoon-phone`: `connect` 73 ms, `get_interactive_elements` 11 ms,
`take_screenshots` 95 ms (the app's own render, scaled to 2,000 pixels on
its longer side), `tap` 38 ms, `hot_reload` 66 ms, `hot_restart` 439 ms,
`press_key` 6 ms. `raccoon-tablet` answers within a few milliseconds of
those.

What differs from a phone:

- `press_back_button` pops the app's routes. With none left the app calls
  `SystemNavigator.pop`, which goes to the host on `flutter/platform`; with
  no host attached it gets a null reply and nothing exits.
- What a host answers has nobody to answer it in a headless run: the
  clipboard reads empty, and a plugin a host serves fails as a missing
  plugin. The window and preferences channels the runner answers itself
  work.
- `get_logs` needs a `LogCollector` in `MarionetteConfiguration`, as on any
  device, and `scroll_to` a scrollable in the app.

## Issues

Report here: [SoFluffyOS/raccoon](https://github.com/SoFluffyOS/raccoon/issues). One tracker for every piece of Raccoon, whichever the bug is in.

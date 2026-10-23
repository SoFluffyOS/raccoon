# raccoon_runtime

The host side of the Raccoon runtime, as Lumide uses it: the
runtime store, runner process management and discovery, the custom-device
configuration, and the frame and input client. Pure Dart, no Flutter, so
`lumide_server` and command-line tools can share it.

Connect with `gpuBuffers: true` (`RunnerClient.connect`) and a runner that
rasterizes on the GPU describes its ring in `GpuBuffers`, then sends frames
as buffer indices, no pixels; `releaseGpuBuffer` gives one back. What
imports the buffers rides a second socket for a native host side: file
descriptors on Linux, which Dart cannot hold, and IOSurface IDs on macOS.
`raccoon_view` has the Linux and macOS sides. A frame the runner cannot put
in a buffer still comes with pixels.

An app that stops before its first frame, such as one whose `main()` awaits
a plugin with no implementation on this host, shows up as
`RunnerClient.startupFailure`: the exception it died of and the channels
nothing answered, read from the log the runner relays, with the plugin
each channel belongs to when the plugin report says it cannot work here.
It waits a moment for a frame (`startupGrace`), and once a frame arrives it
stays null: from then on the app's own error handling rules.

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

The same holds on Linux, macOS and Windows. On every host the runner is
reached through a Unix socket in the host's socket folder, which
`RunnerDiscovery` watches: `$XDG_RUNTIME_DIR/raccoon` on Linux,
`$TMPDIR/raccoon` on macOS, `%TEMP%\raccoon` on Windows, where dart:io
speaks AF_UNIX too but no handles cross, so frames come inline. There the
Flutter tool keeps its devices in `%APPDATA%\.flutter_custom_devices.json`,
and each command starts the helper with Git for Windows' `bash.exe`.

This package is developed inside the Lumide workspace (`packages/raccoon_runtime`)
and resolves through it.

## Issues

Report here: [SoFluffyOS/raccoon](https://github.com/SoFluffyOS/raccoon/issues). One tracker for every Raccoon repository, whichever piece the bug is in. Issues are off on this one.

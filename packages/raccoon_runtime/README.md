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

The devices `raccoon_device setup` registers with the Flutter tool, each a
custom device the helper keeps apart by an instance key (`RaccoonDevice`):
`raccoon` (the host's own size), `raccoon-2` (a second run of the same
project), and the sized ones that start the runner at their logical size
and pixel ratio, `raccoon-phone` (390×844 @3x), `raccoon-tablet`
(820×1180 @2x) and `raccoon-desktop` (1280×800 @1x). `flutter run -d
raccoon-tablet` runs a project on the tablet; a host that shows the app
opens it at that size.

This package is developed inside the Lumide workspace (`packages/raccoon_runtime`)
and resolves through it.

## Issues

Report here: [SoFluffyOS/raccoon](https://github.com/SoFluffyOS/raccoon/issues). One tracker for every Raccoon repository, whichever piece the bug is in. Issues are off on this one.

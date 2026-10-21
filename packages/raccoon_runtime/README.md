# raccoon_runtime

The host side of the Raccoon runtime, as Lumide uses it: the
runtime store, runner process management and discovery, the custom-device
configuration, and the frame and input client. Pure Dart, no Flutter, so
`lumide_server` and command-line tools can share it.

Connect with `gpuBuffers: true` (`RunnerClient.connect`) and a runner that
rasterizes on the GPU describes its ring in `GpuBuffers`, then sends frames
as buffer indices, no pixels; `releaseGpuBuffer` gives one back. The
buffers' descriptors ride a second socket for a native host side, since
Dart cannot hold a raw descriptor; `raccoon_view` has the Linux one. A frame
the runner cannot put in a buffer still comes with pixels.

This package is developed inside the Lumide workspace (`packages/raccoon_runtime`)
and resolves through it.

## Issues

Report here: [SoFluffyOS/raccoon](https://github.com/SoFluffyOS/raccoon/issues). One tracker for every Raccoon repository, whichever piece the bug is in. Issues are off on this one.

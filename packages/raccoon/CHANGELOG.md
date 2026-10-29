## Unreleased

- `RunnerHello.views` and `RunnerHello.view_id`: a runner in views mode says so, and which view a client is connected to (0 for the first). A runner that predates them sends neither: one view.
- `PluginState` gains `SKIPPED`: a native plugin the install left out because it was told to take only what is cached (`RACCOON_PLUGINS=cached`). A client that predates it reads it as unspecified.
- `AppMessage`: the client sends the app a platform message with no reply, as a device's own controls do (`flutter/lifecycle` to put it in the background, `flutter/navigation` to open a link). A runner that predates it ignores it.
- `Resize.view_inset_top`, `_right`, `_bottom` and `_left`, and `Settings`: the client sets what covers the view's edges (an on-screen keyboard), and the device's locales, text scale, dark mode and hour format in place of the host's. A runner that predates them ignores both.
- `PointerPhase` gains `CANCEL`: the host took a press away, and the app drops it with no tap. A runner that predates it already took an unknown phase as a cancel.
- `ClientHello.yields` and `ClientHello.claims`: a host holding a run it doesn't own yields it, and one that owns the run's project claims it; a runner a yielding client holds goes to a claiming newcomer instead of telling it Busy. A runner that predates them ignores both.
- `Frame.format` is per frame: a runner sends a frame read back from the GPU in the byte order it was read, so one run can send BGRA and RGBA frames. Read it on every frame.
- `SharedBuffers.generation` and `ReleaseBuffer.shared_generation`: a shared buffer goes back named by its set, so a release meant for a set since replaced frees nothing in the new one. 0 on either side keeps the old behaviour.

## 0.7.0

- `PointerPhase` gains `PAN_ZOOM_START`, `PAN_ZOOM_UPDATE` and `PAN_ZOOM_END`, `PointerEvent` gains `pan_x`, `pan_y`, `scale` and `rotation`, and `PointerDevice` gains `TRACKPAD`: a trackpad gesture reaches the app as the pan-zoom events the framework delivers it as, so two-finger scrolling works.

## 0.6.0

- `Plugins`: what became of the project's native plugins on the runner's host, one `PluginReport` per plugin: loaded, failed, built nothing, no implementation for this host, or answered by the runner itself. Sent after `RunnerHello`.

## 0.5.0

- `GpuBuffers`: a ring of exported GPU buffers the engine draws into (DRM dmabufs on Linux, IOSurfaces on macOS); what imports them, descriptors or surface IDs, is served on the runner's GPU socket.
- `Frame.in_gpu_buffer` and `gpu_generation`: a frame as a buffer index, no pixels.
- `ClientHello.gpu_buffers`: the client imports them. `ReleaseBuffer.generation`.

## 0.4.0

- `TextEditing`: the client's input method produced a value for the active field.
- `TextField`: the active field's state, from the runner, whenever it changes.
- `ClientHello.composes`: the client has an input method; the runner leaves typing characters to it.

## 0.3.0

- `Busy`: the runner tells a second client who has it, then hangs up.
- `ClientHello.pid`: the client names its process, for that message.

## 0.2.0

- The runner protocol v1 as generated protobuf messages (`ClientMessage`, `RunnerMessage`, `Frame`, `PointerEvent`, ...), from `runner.proto` in the runner.

## 0.1.0

- `Raccoon.isPresent` and `Raccoon.endpoint`, read from `RACCOON_ENDPOINT`.
- `RaccoonProtocol.version`.

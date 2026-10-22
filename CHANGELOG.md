## 0.6.0

- `Plugins`: what became of the project's native plugins on the runner's host, one `PluginStatus` per plugin: loaded, failed, built nothing, no implementation for this host, or answered by the runner itself. Sent after `RunnerHello`.

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

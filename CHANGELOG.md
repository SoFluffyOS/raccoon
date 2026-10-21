## 0.3.0

- `Busy`: the runner tells a second client who has it, then hangs up.
- `ClientHello.pid`: the client names its process, for that message.

## 0.2.0

- The runner protocol v1 as generated protobuf messages (`ClientMessage`, `RunnerMessage`, `Frame`, `PointerEvent`, ...), from `runner.proto` in the runner.

## 0.1.0

- `Raccoon.isPresent` and `Raccoon.endpoint`, read from `RACCOON_ENDPOINT`.
- `RaccoonProtocol.version`.

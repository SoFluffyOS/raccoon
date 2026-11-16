# Raccoon

A hosted Flutter runtime. A small runner hosts your app's Flutter engine and
streams its frames into a pane of [Lumide](https://lumide.dev) or the
[Raccoon Simulator](https://github.com/SoFluffyOS/raccoon_simulator): no
platform build, hot reload always on, a device in your editor's picker.

One repository for the family, each piece with its own history:

| Path | What | Published as |
|---|---|---|
| `packages/raccoon` | the wire protocol and the public Dart API apps and plugin authors see | [pub.dev](https://pub.dev/packages/raccoon), tags `v*` |
| `packages/raccoon_runtime` | the host side: runtime store, runner process management and discovery, the `raccoon` devices, frame and input client (pure Dart) | a path dependency |
| `packages/raccoon_view` | the Flutter widgets that show a hosted app: `RaccoonView`, `RaccoonCanvas`, `RaccoonBoard` | a path dependency |
| `packages/raccoon_mcp` | an MCP server for coding agents: run apps on Raccoon devices, screenshot, tap, type, hot reload, through the simulator's control endpoint or headless runners of its own | not published yet (`publish_to: none`, `raccoon_runtime` by path); `dart pub global activate --source git https://github.com/SoFluffyOS/raccoon.git --git-path packages/raccoon_mcp` |
| `native/raccoon_runner` | the runner: C++ on Flutter's embedder API; hosts the app, serves frames and GPU buffers, loads native plugins | [releases](https://github.com/SoFluffyOS/raccoon/releases), tags `runner-v*` |

Lumide and the simulator take this repository as one git submodule.

## Testing and agents

A Raccoon device needs no emulator, no native build and no display: the
runner draws headless, and `RACCOON_HEADLESS=1` tells it no host is coming.
[Testing on Raccoon devices](packages/raccoon_runtime/README.md#testing-on-raccoon-devices)
has `flutter test integration_test` and `flutter drive` on `raccoon-phone`,
`RaccoonTestDevice` from plain `dart test`, the CI recipe
(`.github/workflows/device-tests.yml`, one Ubuntu job, about 2 min) and
marionette_mcp over the app's VM service.
[raccoon_mcp](packages/raccoon_mcp/README.md) gives an agent the devices as
MCP tools: with the Raccoon Simulator open it acts on the board, where you
watch it; with none, it runs the apps headless.

## Issues

One tracker for everything Raccoon:
[issues](https://github.com/SoFluffyOS/raccoon/issues). Labels name the piece
(`protocol`, `runtime`, `view`, `runner`, `simulator`, `lumide`) and the host.

## Develop

Each package resolves on its own: `dart pub get` in `packages/raccoon_runtime`,
`flutter pub get` in `packages/raccoon_view`. The runner builds with CMake,
see `native/raccoon_runner/README.md`. A protocol change: edit
`native/raccoon_runner/proto/raccoon/v1/runner.proto`, rebuild the runner,
run `packages/raccoon/tool/gen_proto.sh`, bump `packages/raccoon`.

## History

Merged on 2026-10-22 from `SoFluffyOS/raccoon_runtime`, `raccoon_view` and
`raccoon_runner`, since archived; every commit kept under its directory, the
runner's tags renamed `runner-v*`.

## License

BSD-3-Clause, see `LICENSE`.

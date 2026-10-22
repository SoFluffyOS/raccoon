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
| `native/raccoon_runner` | the runner: C++ on Flutter's embedder API; hosts the app, serves frames and GPU buffers, loads native plugins | [releases](https://github.com/SoFluffyOS/raccoon/releases), tags `runner-v*` |

Lumide and the simulator take this repository as one git submodule.

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

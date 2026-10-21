# raccoon_runner

The Raccoon runtime's runner: hosts Flutter apps on the C embedder API, with a
pre-warmed engine, for Lumide. Part of the Lumide monorepo as a git
submodule at `native/raccoon_runner`. Design notes: `docs/internal_docs/raccoon/`.

## M0, first milestone: a frame out of the runner

The runner loads the prebuilt debug engine (`libflutter_engine.so`) for the
active Flutter SDK's engine revision, runs an app bundle through the software
renderer, and writes a frame to a PPM file.

```sh
tool/render_example.sh            # fetch engine, build example and runner, render build/frame.png
```

Linux first, on the developer's workstation. The per-host seams (engine
loading, sockets, paths) are kept small so macOS and Windows follow later.

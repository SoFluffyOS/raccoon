# raccoon_mcp

An MCP server over stdio that lets a coding agent drive Flutter apps on
Raccoon devices: run a project on `raccoon-phone` and `raccoon-tablet`,
take screenshots, tap, type, resize, read the logs, hot reload. With the
[Raccoon Simulator](https://github.com/SoFluffyOS/raccoon_simulator) open,
every call happens on its board, so you watch the agent work. With none
open, the same tools run the apps themselves, no window, as CI wants.

Measured on a Linux workstation (Ryzen 9, RX 7600M XT), `example/hello`
through the simulator, over stdio from a client script:

| Call | Time |
|---|---|
| server start (`initialize`) | 119 ms |
| `run` on `raccoon-phone`, build cached / `build/` removed | 1.3 s / 2.7 s |
| `screenshot`, 1170 × 2532 / `logical: true`, 390 × 844 | 404 ms / 379 ms |
| `tap` | 3 ms |
| `resize`, to the first frame at the new size | 14 ms |
| `hot_reload` / again | 69 ms / 38 ms |
| `hot_restart` | 263 ms |
| `logs` | 2 to 5 ms |
| `stop` | 75 to 128 ms |

A screenshot waits for the app to settle (250 ms without a new frame), then
encodes the PNG: take one after a tap and it shows what the tap did.

## Install

Not on pub.dev yet. From GitHub, which precompiles it:

```sh
dart pub global activate --source git https://github.com/SoFluffyOS/raccoon.git \
  --git-path packages/raccoon_mcp
```

or from a checkout of this repository, which runs it from source (the first
start compiles, about 3 s):

```sh
dart pub global activate --source path packages/raccoon_mcp
```

Both resolve `raccoon_runtime` from the same checkout. Either puts
`raccoon_mcp` in `~/.pub-cache/bin`; have it on your `PATH`. The devices come
from the Flutter tool's custom devices: register them once, as in
[Testing on Raccoon devices](../raccoon_runtime/README.md#testing-on-raccoon-devices)
(`raccoon_device setup`, then `add phone`, `add tablet`), or let the
simulator's setup and its device menu do it.

## Register it with an MCP client

```sh
claude mcp add raccoon -- raccoon_mcp
```

Other clients take the same command in their MCP config:

```json
{ "mcpServers": { "raccoon": { "command": "raccoon_mcp" } } }
```

| Flag | What it does |
|---|---|
| `--host auto` | The open simulator's board when there is one, headless otherwise (the default) |
| `--host simulator` | Only the simulator; a call fails when none is open |
| `--host headless` | Never the simulator, even when one is open |
| `--flutter <path>` | The Flutter tool headless runs use (`flutter` on the `PATH`) |
| `--verbose` | Headless: each action on stderr |

## A session

Open the simulator, then ask the agent something like: *run
`native/raccoon_runner/example/hello` on raccoon-phone and raccoon-tablet,
screenshot both, tap the box on each and check it turns green*. What it
calls, and what you see:

1. `list_devices`: the phone at 390 × 844 @3x, the tablet at 820 × 1180 @2x,
   nothing on them yet.
2. `run` with the project and `raccoon-phone`, then `raccoon-tablet`. The
   board comes up, each app shows from the call as starting, then live.
   Runs of one project build in turn.
3. `screenshot` with `device` and `logical: true`, on each: a red box in the
   middle.
4. `tap` at (195, 422) on the phone, (410, 590) on the tablet. You see the
   boxes turn green on the board; the next `screenshot` shows the agent the
   same.
5. `resize` the tablet to 600 × 800 @2x. Its frame on the board takes the
   size, as the size menu does, and the app lays out at it.
6. `logs` with `source: runner`: the runner's own lines, `🦝 first frame 243
   ms after launch` among them.
7. `hot_reload` after an edit, `stop` when done.

Each action is a line in the simulator's log (`Agent: tap 195, 422 on
hello@phone`), and the board pans the app it acts on into view.

## Tools

Every result is JSON and says `host`: `simulator` or `headless`, and `ms`,
the time the host took. Coordinates and sizes are logical pixels. A call
points at an app with `device` (`raccoon-phone`, or just `phone`) and, when
several apps run on that device, `app` (the project's pubspec name); while
one app runs, neither is needed. A failure comes back as a tool error with a
code: `bad_params`, `no_app`, `ambiguous`, `unsupported` or `failed`.

| Tool | Takes | Returns |
|---|---|---|
| `list_devices` | | The registered Raccoon devices, each with `size` (`width`, `height`, `pixel_ratio`, or null for one the host sizes) and its `apps`: `name`, `project`, `size` now, `started_by` (`agent`, `host`, `editor`, `headless`), `can_reload`, `vm_service` |
| `run` | `project` (absolute, or from where the server runs), `device` (`raccoon-phone` by default), `target` | The app, once it has drawn and the tool is attached, and `startup_ms`. An app already running there is returned as it is |
| `stop` | `device`, `app` | `stopped`: the app's name. Its runner goes too |
| `hot_reload`, `hot_restart` | `device`, `app` | Once the app drew after it; a compile error fails it with the tool's message. Only for apps started through `run` or the simulator's own Run |
| `screenshot` | `device`, `app`, `logical`, `scale` | The settled frame as an image, pixel-exact, GPU path included, and its sizes: `width`, `height` of the image, `frame_width`, `frame_height`, `logical_width`, `logical_height`, `pixel_ratio`, `sequence` |
| `tap` | `x`, `y` | Once the events are sent |
| `long_press` | `x`, `y`, `hold_ms` (650) | After the hold |
| `drag` | `from_x`, `from_y`, `to_x`, `to_y`, `duration_ms` (300) | After the finger lifts; short and fast is a fling |
| `scroll` | `x`, `y`, `dx`, `dy` | A mouse wheel: positive `dy` scrolls the content down |
| `type_text` | `text` | Into the focused field, in place of its selection, as an input method types. Tap the field first |
| `press_key` | `key`, `modifiers` | `enter`, `escape`, `backspace`, `tab`, `space`, `delete`, `home`, `end`, `page_up`, `page_down`, the arrows, or one character; `shift`, `control`, `alt`, `meta` held around it |
| `logs` | `source` (`app`, `runner`, `tool`), `contains`, `pattern` (a regular expression), `last` (100, 0 for all) | `lines`, each with its `source` and `text`, and how many `matched` of the `total` |
| `resize` | `width`, `height`, `pixel_ratio` (kept when not given) | The app at its new size, once it drew at it |

`widget_tree` and `tap_widget` from #48 are not here: an app's widgets and
semantics are the job of [marionette_mcp](https://pub.dev/packages/marionette_mcp)
over the app's VM service (`vm_service` in every app result), which runs
beside this server, and of Lumide's own tools for apps run in Lumide.

The app's lines reach `logs` as the Flutter tool relays them, a few hundred
milliseconds after the app printed them. `press_key` sends key events: with
the simulator, whose input method types text, a key types no character
there; use `type_text` for text.

## With no simulator open

The same tools, the same results, `host: headless`. Each `run` is a
`RaccoonTestDevice` of `raccoon_runtime`: its own `flutter run -d <device>
--machine` and a connection of its own to the runner, which draws with no
window and no display. Measured on the same machine: `run` 1.3 s, a full
phone screenshot 346 to 390 ms, `hot_reload` 66 ms, `hot_restart` 349 ms,
`resize` 17 ms.

What differs:

- Nobody watches: there is no board and no log panel. `--verbose` prints
  each action on stderr.
- The runs belong to this server and stop with it, when the client closes
  stdin or the server gets SIGINT or SIGTERM.
- `logs` has the app's lines and the runner's; the Flutter tool's progress
  and reload lines show as the app's.
- A key with a character types it: no host input method is there to.
- Opening a simulator later does not move them: calls at an app this server
  runs headless stay headless, the rest go to the simulator.

`--host headless` keeps a session headless with a simulator open, as for a
test that should not touch the board. The package's own test drives
`example/hello` on a phone and a tablet over stdio either way:

```sh
dart test                              # on the simulator's board, if one is open
RACCOON_MCP_HEADLESS=1 dart test       # headless too
```

## How it reaches the simulator

A runner serves one client at a time, and the simulator is that client for
every app on its board, so the server cannot open a runner's socket beside
it. The simulator serves a control endpoint instead (`RaccoonControlServer`
in `raccoon_runtime`): HTTP on 127.0.0.1 at a port of the system's choosing,
answering only requests with its token and no browser `Origin`. The port and
token are in a file only your user can read, `$XDG_RUNTIME_DIR/raccoon/control/`
on Linux, the temporary folder's `raccoon/control/` elsewhere, where the
server finds the newest live simulator. `RACCOON_CONTROL=<file>` names one.
The input and the frames go through the simulator's own connection to each
runner, which is why the board shows them.

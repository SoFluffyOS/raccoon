# raccoon

The public Dart API of the Raccoon runtime, the hosted runtime that Lumide
uses to launch Flutter apps instantly with hot reload always on.

Apps and plugin authors depend on this package. It is pure Dart and BSD-3-Clause
licensed, like Flutter, so a plugin can use any license.

```dart
import 'package:raccoon/raccoon.dart';

final raccoon = Raccoon();
if (raccoon.isPresent) {
  // Hosted by the runner: use its services instead of the desktop embedder's.
}
```

## The pieces

| | |
|---|---|
| [raccoon](https://github.com/SoFluffyOS/raccoon/tree/main/packages/raccoon) | this package: the API apps and plugins see, and the wire protocol |
| [raccoon_runner](https://github.com/SoFluffyOS/raccoon/tree/main/native/raccoon_runner) | the runtime: hosts the Flutter engine, serves frames over a socket |
| [raccoon_runtime](https://github.com/SoFluffyOS/raccoon/tree/main/packages/raccoon_runtime) | the Dart client: find a runner, talk to it, set up the `raccoon` devices |
| [raccoon_view](https://github.com/SoFluffyOS/raccoon/tree/main/packages/raccoon_view) | the Flutter widgets that show a hosted app |
| [raccoon_simulator](https://github.com/SoFluffyOS/raccoon_simulator) | a window for it, from any editor |

[Lumide](https://lumide.dev) runs apps on Raccoon in a pane.

## Issues

All of Raccoon's issues live here. Runner, runtime, view, simulator, Lumide's pane: one tracker, whichever piece it is in. Pick the piece in the form if you know it. Skip it if you don't.

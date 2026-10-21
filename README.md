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

The runner, its protocol and the design notes live in the `raccoon` repository.

import 'package:raccoon/raccoon.dart';

/// What a view needs from a runner: frames in, size and input out.
/// [RunnerClient] implements it over the socket; tests use fakes.
abstract interface class RunnerConnection {
  /// The latest frame first, then every new one.
  Stream<Frame> get frames;

  void resize(int width, int height, double pixelRatio);

  void sendPointer(PointerEvent event);

  void sendKey(KeyEvent event);
}

/// A connection that can carry a host's input method: the host mirrors the
/// app's active text field in its own IME and sends back what it produces.
/// Only a client that said so in its hello ([composes]) should send. A
/// [RunnerConnection] too, so a view can tell the two apart by type.
abstract interface class ComposingConnection implements RunnerConnection {
  /// Whether this client told the runner it composes; when false the runner
  /// types characters from keys itself and [sendTextEditing] is unused.
  bool get composes;

  /// The active field's latest state first, then every change.
  Stream<TextField> get textFields;

  TextField? get latestTextField;

  void sendTextEditing(TextEditing editing);
}

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

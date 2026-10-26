import 'dart:typed_data';

import 'package:raccoon/raccoon.dart';

/// Serves one platform channel for the hosted app, the way a desktop
/// embedder's plugin would. Returns the reply bytes, or null for "no plugin",
/// which the app sees as a null reply.
typedef PlatformChannelHandler = Future<Uint8List?> Function(Uint8List data);

/// What a view needs from a runner: frames in, size and input out.
/// [RunnerClient] implements it over the socket; tests use fakes.
abstract interface class RunnerConnection {
  /// The latest frame first, then every new one.
  Stream<Frame> get frames;

  /// Sizes the app: [width] and [height] in physical pixels, at
  /// [pixelRatio] physical pixels to a logical one.
  void resize(int width, int height, double pixelRatio);

  /// Sends a pointer event, its position in the frame's pixels.
  void sendPointer(PointerEvent event);

  /// Sends a key going down, up or repeating.
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

  /// The active field's latest state; null until the runner sent one.
  TextField? get latestTextField;

  /// Sends the value the host's input method produced for the active
  /// field.
  void sendTextEditing(TextEditing editing);
}

/// A connection that can carry GPU buffers: frames arrive as buffer indices
/// and the host's native side shows them from the runner's GPU socket. Only
/// a client that said so in its hello ([gpuBuffers]) gets them.
abstract interface class GpuBufferConnection implements RunnerConnection {
  /// Whether this client asked for GPU buffers in its hello.
  bool get gpuBuffers;

  /// Each set of GPU buffers as the runner describes it, the latest first.
  Stream<GpuBuffers> get gpuBufferSets;

  /// The current set of GPU buffers; null until the runner described one.
  GpuBuffers? get latestGpuBuffers;

  /// Gives a GPU buffer back to the runner once the host is done with it.
  void releaseGpuBuffer(int generation, int index);
}

/// A connection that can serve one of the hosted app's channels: what the
/// app sends on [channel] goes to the handler, whose answer goes back. A
/// view serves what belongs to it this way (the app's mouse cursor).
abstract interface class ChannelConnection implements RunnerConnection {
  /// Serves [channel] with [handler], in place of any handler before.
  void registerChannel(String channel, PlatformChannelHandler handler);

  /// Stops serving [channel]; the app's calls on it get "no plugin" again.
  void unregisterChannel(String channel);
}

/// A connection whose client can ask for frames with pixels while it is on
/// GPU buffers (#202): a view shows those at once rather than waiting for
/// its ring to go quiet (#204).
abstract interface class CaptureConnection implements RunnerConnection {
  /// Whether a capture wants pixel frames now.
  bool get pixelsWanted;
}

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

/// A connection that can carry GPU buffers: frames arrive as buffer indices
/// and the host's native side shows them from the runner's GPU socket. Only
/// a client that said so in its hello ([gpuBuffers]) gets them.
abstract interface class GpuBufferConnection implements RunnerConnection {
  bool get gpuBuffers;

  /// Each set of GPU buffers as the runner describes it, the latest first.
  Stream<GpuBuffers> get gpuBufferSets;

  GpuBuffers? get latestGpuBuffers;

  /// Gives a GPU buffer back to the runner once the host is done with it.
  void releaseGpuBuffer(int generation, int index);
}

/// A connection that can serve one of the hosted app's channels: what the
/// app sends on [channel] goes to the handler, whose answer goes back. A
/// view serves what belongs to it this way (the app's mouse cursor).
abstract interface class ChannelConnection implements RunnerConnection {
  void registerChannel(String channel, PlatformChannelHandler handler);

  void unregisterChannel(String channel);
}

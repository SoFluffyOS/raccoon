import 'dart:async';

import 'package:raccoon/raccoon.dart' as rc;
import 'package:raccoon_runtime/raccoon_runtime.dart' show GpuBufferConnection;

/// Gives a connection's GPU buffers back as the runner names them, while no
/// view shows its ring: a view gone (off a board, with its tab) from a
/// connection that stays. Nothing else would, and with its ring full the
/// runner draws every frame by readback, about ten a second, which its
/// shared vsync holds every other view of the app to.
final class RingDrain {
  RingDrain._(GpuBufferConnection connection) {
    _frames = connection.frames.listen(
      (frame) {
        if (!frame.inGpuBuffer) return;
        connection.releaseGpuBuffer(frame.gpuGeneration, frame.bufferIndex);
      },
      onError: (Object _) {},
      onDone: () {
        if (identical(_drains[connection], this)) _drains[connection] = null;
      },
    );
  }

  static final _drains = Expando<RingDrain>('raccoon view ring drains');

  late final StreamSubscription<rc.Frame> _frames;

  /// Starts giving back [connection]'s GPU buffers, unless already.
  static void start(GpuBufferConnection connection) {
    _drains[connection] ??= RingDrain._(connection);
  }

  /// Stops it: a view took [connection]'s ring.
  static void stop(GpuBufferConnection connection) {
    final drain = _drains[connection];
    if (drain == null) return;
    _drains[connection] = null;
    unawaited(drain._frames.cancel());
  }
}

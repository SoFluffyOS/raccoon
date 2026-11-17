import 'dart:async';

import 'package:raccoon/raccoon.dart';
import 'package:raccoon_runtime/src/frame_image.dart';
import 'package:raccoon_runtime/src/runner_client.dart';

/// The app's frame once it settles: the latest frame after no new one has
/// come for [settle], or the latest at [timeout] for an app that never
/// stops animating. Taken after input, it shows what the input did.
///
/// A client on GPU buffers takes pixel frames meanwhile
/// ([RunnerClient.wantPixels]); a view showing its ring goes on showing it.
/// GPU buffer frames that come before the switch go back to the runner
/// when [releaseGpuFrames], for a client nothing shows; a host whose view
/// holds the ring leaves them to it. The frame's pixels are read as it
/// settles, so a client that reuses its pixel buffers may draw on.
Future<RaccoonFrame> settledFrame(
  RunnerClient client, {
  required double pixelRatio,
  Duration settle = const Duration(milliseconds: 250),
  Duration timeout = const Duration(seconds: 5),
  bool releaseGpuFrames = true,
  String name = 'the app',
}) async {
  client.wantPixels(true);
  Frame? latest = switch (client.latestFrame) {
    final frame? when !frame.inGpuBuffer => frame,
    _ => null,
  };
  final done = Completer<RaccoonFrame>();
  void finish() {
    final frame = latest;
    if (frame == null || done.isCompleted) return;
    try {
      done.complete(RaccoonFrame(frame, pixelRatio, frameImage(frame)));
    } on Object catch (error, stackTrace) {
      done.completeError(error, stackTrace);
    }
  }

  Timer? quiet;
  void rest() {
    quiet?.cancel();
    quiet = Timer(settle, finish);
  }

  // On frames, not messages: a GPU buffer frame heard only on messages
  // has gone back already (#414).
  final subscription = client.frames.listen((frame) {
    if (frame.inGpuBuffer) {
      if (releaseGpuFrames) {
        client.releaseGpuBuffer(frame.gpuGeneration, frame.bufferIndex);
      }
      return;
    }
    latest = frame;
    rest();
  }, onError: (Object _) {});
  rest();
  final cap = Timer(timeout, () {
    if (done.isCompleted) return;
    if (latest != null) {
      finish();
      return;
    }
    done.completeError(TimeoutException('no frame from $name', timeout));
  });
  final closed = client.closed.then((_) {
    if (done.isCompleted) return;
    done.completeError(StateError('$name hung up before its frame'));
  });
  closed.ignore();
  try {
    return await done.future;
  } finally {
    quiet?.cancel();
    cap.cancel();
    await subscription.cancel();
    client.wantPixels(false);
  }
}

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/widgets.dart';

/// Uses the camera plugin as an app does, against the runner's test camera:
/// lists the cameras, takes a picture and decodes it, streams frames in
/// each format, then records a video. The test pattern's top three quarters
/// are colour bars, white first and blue last, so a picture or a frame is
/// checked by its colour at those two places; a picture given as the source
/// is reported by its colours there. Shows the preview meanwhile, paused
/// while the first stream's rate is measured. Prints a CAMERA: line per
/// step, then CAMERA:done, or CAMERA:error and why.
///
/// Frames are streamed through the platform interface: the method channel
/// implementation says it does not stream, so CameraController's
/// startImageStream asserts in a debug build before asking.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preview = ValueNotifier<CameraController?>(null);
  runApp(_Preview(preview));
  try {
    final cameras = await availableCameras();
    _say('cameras ${cameras.map((c) => c.lensDirection.name).join(',')}');

    final controller = CameraController(
      cameras.first,
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    await controller.initialize();
    preview.value = controller;
    final size = controller.value.previewSize;
    _say('initialized ${size?.width.toInt()}x${size?.height.toInt()}');

    // Long enough for the test to see the preview in a frame.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final picture = await controller.takePicture();
    final image = await _decode(await picture.readAsBytes());
    _say('picture ${await _bars(image)} ${picture.path}');

    // Every preview frame is a frame the test's client reads back; paused,
    // the stream's rate is the stream's own, on a slow machine too.
    await controller.pausePreview();
    final yuv = await _frames(controller, 10);
    final first = yuv.frames.first;
    final y = first.planes[0];
    final white = y.bytes[_at(first.width, first.height, 1) ~/ 4];
    final blue = y.bytes[_at(first.width, first.height, 13) ~/ 4];
    _say(
      'stream yuv420 planes=${first.planes.length} '
      '${first.width}x${first.height} y=$white/$blue '
      'fps=${yuv.fps.toStringAsFixed(1)}',
    );
    preview.value = null;
    await controller.dispose();

    for (final group in [ImageFormatGroup.bgra8888, ImageFormatGroup.jpeg]) {
      final other = CameraController(
        cameras.last,
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: group,
      );
      await other.initialize();
      final frames = await _frames(other, 3);
      final frame = frames.frames.first;
      final ui.Image decoded;
      if (group == ImageFormatGroup.jpeg) {
        decoded = await _decode(frame.planes.single.bytes);
      } else {
        decoded = await _fromBgra(frame);
      }
      _say(
        'stream ${group.name()} planes=${frame.planes.length} '
        'raw=${frame.format.raw} ${await _bars(decoded)}',
      );
      await other.dispose();
    }

    // A recording of 600 ms, a 400 ms pause, then 400 ms more: a second of
    // video where the runner records, and why not elsewhere.
    final recorder = CameraController(
      cameras.first,
      ResolutionPreset.low,
      enableAudio: false,
    );
    await recorder.initialize();
    try {
      await recorder.startVideoRecording();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await recorder.pauseVideoRecording();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await recorder.resumeVideoRecording();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final video = await recorder.stopVideoRecording();
      _say('video ${video.path}');
    } on CameraException catch (error) {
      _say('video refused ${error.code}');
    }
    await recorder.dispose();

    // A camera nobody shows: the runner stops drawing it at its frame rate.
    final idle = CameraController(
      cameras.first,
      ResolutionPreset.low,
      enableAudio: false,
    );
    await idle.initialize();
    _say('idle');
    await Future<void>.delayed(const Duration(seconds: 2));
    _say('idle end');
    // Shown now: the preview comes back to its frame rate.
    preview.value = idle;
    _say('shown');
    await Future<void>.delayed(const Duration(seconds: 1));
    _say('shown end');
    preview.value = null;
    await idle.dispose();
    _say('done');
  } catch (error) {
    _say('error $error');
  }
}

void _say(String line) {
  // ignore: avoid_print
  print('CAMERA:$line');
}

/// The offset of the pixel a quarter down, in the middle of the bar at
/// [fourteenths] of the width, in a buffer of four bytes a pixel.
int _at(int width, int height, int fourteenths) =>
    ((height ~/ 4) * width + width * fourteenths ~/ 14) * 4;

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  return (await codec.getNextFrame()).image;
}

Future<ui.Image> _fromBgra(CameraImageData frame) {
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    frame.planes.single.bytes,
    frame.width,
    frame.height,
    ui.PixelFormat.bgra8888,
    done.complete,
  );
  return done.future;
}

/// 'bars ok' when the first bar is white and the last blue, 'bars bad'
/// otherwise; then the colours seen there, as left= and right=, for a
/// picture given as the camera's source.
Future<String> _bars(ui.Image image) async {
  final data = await image.toByteData();
  if (data == null) return 'bars unreadable';
  List<int> rgb(int offset) => [
        data.getUint8(offset),
        data.getUint8(offset + 1),
        data.getUint8(offset + 2),
      ];
  final white = rgb(_at(image.width, image.height, 1));
  final blue = rgb(_at(image.width, image.height, 13));
  final ok = white.every((c) => c > 230) &&
      blue[0] < 30 &&
      blue[1] < 30 &&
      blue[2] > 220;
  return '${ok ? 'bars ok' : 'bars bad'} '
      'left=${white.join(',')} right=${blue.join(',')}';
}

/// [count] frames of the camera's image stream, and how many came a second.
Future<({List<CameraImageData> frames, double fps})> _frames(
  CameraController controller,
  int count,
) async {
  final frames = <CameraImageData>[];
  final done = Completer<void>();
  final clock = Stopwatch();
  final stream = CameraPlatform.instance.onStreamedFrameAvailable(
    controller.cameraId,
  );
  final subscription = stream.listen((image) {
    if (frames.isEmpty) clock.start();
    if (frames.length < count) frames.add(image);
    if (frames.length == count && !done.isCompleted) done.complete();
  });
  await done.future.timeout(const Duration(seconds: 10));
  clock.stop();
  await subscription.cancel();
  final seconds = clock.elapsedMicroseconds / 1e6;
  return (frames: frames, fps: seconds == 0 ? 0.0 : (count - 1) / seconds);
}

class _Preview extends StatelessWidget {
  const _Preview(this.controller);

  final ValueNotifier<CameraController?> controller;

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.ltr,
        child: ValueListenableBuilder(
          valueListenable: controller,
          builder: (context, value, _) => switch (value) {
            final controller? => CameraPreview(controller),
            null => const ColoredBox(color: Color(0xFF202020)),
          },
        ),
      );
}

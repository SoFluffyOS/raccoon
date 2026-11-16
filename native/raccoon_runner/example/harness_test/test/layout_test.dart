// example/hello's layout on a phone, a tablet and a desktop at once, one
// call for the three: each frame at its device's size, the box in the
// middle at its own logical size whatever the screen, and a golden each.

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

const blue = 0xFF1E88E5;
const red = 0xFFE53935;

final hello = p.normalize(p.join(Directory.current.path, '..', 'hello'));
final gpuBuffers = Platform.environment['RACCOON_GPU_BUFFERS'] == '1';

String hex(int color) => '0x${color.toRadixString(16).toUpperCase()}';

void main() {
  test('the box sits in the middle of a phone, a tablet and a desktop', () async {
    final clock = Stopwatch()..start();
    final devices = await RaccoonTestDevice.launchAll(
      hello,
      gpuBuffers: gpuBuffers,
    );
    try {
      print(
        'launched ${devices.length} devices in '
        '${clock.elapsedMilliseconds} ms: '
        '${devices.map((d) => '${d.deviceId} ${d.startup.inMilliseconds} ms').join(', ')}',
      );
      expect(devices.map((d) => d.deviceId), RaccoonTestDevice.presets);
      for (final device in devices) {
        final frame = await device.frame();
        final (w, h) = (frame.logicalWidth, frame.logicalHeight);
        expect((w, h), (device.size.width, device.size.height));
        expect(
          (frame.width, frame.height),
          (
            (device.size.width * device.size.pixelRatio).round(),
            (device.size.height * device.size.pixelRatio).round(),
          ),
        );
        // The box is 240 x 120 on every device: red just inside its
        // edges, blue just outside.
        expect(hex(frame.colorAt(w / 2 - 118, h / 2 - 58)), hex(red));
        expect(hex(frame.colorAt(w / 2 + 118, h / 2 + 58)), hex(red));
        expect(hex(frame.colorAt(w / 2 - 122, h / 2)), hex(blue));
        expect(hex(frame.colorAt(w / 2, h / 2 + 62)), hex(blue));
        final result = await frame.compareToGolden(
          p.join('goldens', 'hello_${device.deviceId.substring(8)}.png'),
          channelTolerance: 2,
          maxDifferingRatio: 0.02,
        );
        print('  ${device.deviceId} ${frame.width}x${frame.height}: $result');
        expect(result.matches, isTrue, reason: '$result');
      }
    } finally {
      await Future.wait(devices.map((d) => d.stop()));
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

// example/hello on Raccoon devices, driven from plain `dart test`: no
// emulator, no window. Needs the devices registered (raccoon_device setup,
// then add phone, tablet, desktop) and a runner built or downloaded.
//
//   dart test                            # frames by readback, as on CI
//   RACCOON_GPU_BUFFERS=1 dart test      # frames in GPU buffers, as hosts take them
//   RACCOON_UPDATE_GOLDENS=1 dart test   # writes the goldens again

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

const blue = 0xFF1E88E5;
const red = 0xFFE53935;
const green = 0xFF43A047;

final hello = p.normalize(p.join(Directory.current.path, '..', 'hello'));
final gpuBuffers = Platform.environment['RACCOON_GPU_BUFFERS'] == '1';

/// The text is drawn in a fallback font the machine has, which differs
/// from one to the next: its edges may, the rest may not.
Future<void> expectGolden(RaccoonFrame frame, String name) async {
  final result = await frame.compareToGolden(
    p.join('goldens', name),
    channelTolerance: 2,
    maxDifferingRatio: 0.02,
  );
  print('  $result');
  expect(result.matches, isTrue, reason: '$result');
}

String hex(int color) => '0x${color.toRadixString(16).toUpperCase()}';

void main() {
  test(
    'raccoon-phone: a tap, the pixels, a golden, hot reload and restart',
    () async {
      final clock = Stopwatch()..start();
      final phone = await RaccoonTestDevice.launch(
        hello,
        device: 'raccoon-phone',
        gpuBuffers: gpuBuffers,
      );
      try {
        print(
          'launched raccoon-phone in ${phone.startup.inMilliseconds} ms '
          '(gpu buffers: $gpuBuffers), VM service ${phone.vmServiceUri}',
        );
        expect(phone.vmServiceUri, startsWith('http://'));
        expect(
          phone.vmServiceWebSocketUri,
          allOf(startsWith('ws://'), endsWith('/ws')),
        );

        var frame = await phone.frame();
        expect((frame.width, frame.height), (1170, 2532));
        expect((frame.logicalWidth, frame.logicalHeight), (390, 844));
        expect(hex(frame.colorAt(10, 10)), hex(blue));
        expect(hex(frame.colorAt(195, 422)), hex(red));
        await expectGolden(frame, 'hello_phone.png');

        var mark = clock.elapsedMilliseconds;
        await phone.tap(195, 422);
        frame = await phone.frame();
        expect(hex(frame.colorAt(150, 400)), hex(green));
        print('tap to a green frame: ${clock.elapsedMilliseconds - mark} ms');

        // State stays through a hot reload and goes with a restart.
        mark = clock.elapsedMilliseconds;
        await phone.hotReload();
        frame = await phone.frame();
        expect(hex(frame.colorAt(150, 400)), hex(green));
        print('hot reload: ${clock.elapsedMilliseconds - mark} ms');

        mark = clock.elapsedMilliseconds;
        await phone.hotRestart();
        frame = await phone.frame();
        expect(hex(frame.colorAt(150, 400)), hex(red));
        print('hot restart: ${clock.elapsedMilliseconds - mark} ms');

        expect(phone.logLines, contains(contains('first frame')));
        final png = await frame.png();
        expect(png.sublist(1, 4), 'PNG'.codeUnits);
      } finally {
        final mark = clock.elapsedMilliseconds;
        await phone.stop();
        print('stop: ${clock.elapsedMilliseconds - mark} ms');
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

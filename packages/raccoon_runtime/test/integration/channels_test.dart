// Drives the real runner: the channels the runner answers itself: clipboard,
// window, shared preferences, camera, locales and lifecycle. Skipped when the
// runner or its inputs are not built; see
// native/raccoon_runner/tool/render_example.sh. What the files share is in
// test/support/runner_fixture.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:path/path.dart' as p;
import 'package:raccoon/raccoon.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

import '../support/runner_fixture.dart';

// The fixture's helpers, by the names these tests have always used.
const _blue = blue;
const _green = green;
final _pictureLine = pictureLine;
const _pixel = pixel;
const _expectExit = expectExit;

const _purple = (r: 0x8E, g: 0x24, b: 0xAA);

/// A PNG of [width] x [height], 8-bit RGB, each pixel [rgb] of its position.
Uint8List _png(int width, int height, List<int> Function(int x, int y) rgb) {
  final crcTable = List<int>.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = c & 1 == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });
  List<int> chunk(String type, List<int> data) {
    final body = [...ascii.encode(type), ...data];
    var crc = 0xFFFFFFFF;
    for (final byte in body) {
      crc = crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    crc ^= 0xFFFFFFFF;
    List<int> word(int v) => [
      v >> 24 & 0xFF,
      v >> 16 & 0xFF,
      v >> 8 & 0xFF,
      v & 0xFF,
    ];
    return [...word(data.length), ...body, ...word(crc)];
  }

  final rows = <int>[
    for (var y = 0; y < height; y++) ...[
      0, // no filter
      for (var x = 0; x < width; x++) ...rgb(x, y),
    ],
  ];
  return Uint8List.fromList([
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    ...chunk('IHDR', [
      ...[0, 0, width >> 8, width & 0xFF],
      ...[0, 0, height >> 8, height & 0xFF],
      8, 2, 0, 0, 0, // 8 bits, RGB, deflate, no filter, no interlace
    ]),
    ...chunk('IDAT', zlib.encode(rows)),
    ...chunk('IEND', []),
  ]);
}

/// A JSON method-channel reply, as flutter/platform expects: a one-element
/// array holding the result.
Uint8List _jsonReply(Object? result) =>
    Uint8List.fromList(utf8.encode(jsonEncode([result])));

void main() {
  final RunnerFixture(
    :environment,
    :binary,
    :assets,
    :engineDir,
    :icu,
    :ready,
    :channelsAssets,
    :cameraAssets,
    :testVideo,
  ) = RunnerFixture();
  test(
    "answers the app's clipboard request through the client",
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      final calls = <String>[];
      client.registerChannel('flutter/platform', (data) async {
        final call = jsonDecode(utf8.decode(data)) as Map;
        calls.add(call['method'] as String);
        return switch (call['method']) {
          'Clipboard.getData' => _jsonReply({'text': 'raccoon'}),
          _ => null,
        };
      });
      try {
        await client.frames.first.timeout(const Duration(seconds: 15));
        for (final (phase, buttons) in [
          (PointerPhase.POINTER_PHASE_DOWN, 1),
          (PointerPhase.POINTER_PHASE_UP, 0),
        ]) {
          client.sendPointer(
            PointerEvent(
              phase: phase,
              x: 400,
              y: 300,
              buttons: Int64(buttons),
              device: PointerDevice.POINTER_DEVICE_MOUSE,
              pointerId: 1,
            ),
          );
        }
        await client.frames
            .firstWhere((f) => _pixel(f, 400, 300) == _purple)
            .timeout(const Duration(seconds: 10));
        expect(calls, contains('Clipboard.getData'));
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'the runner answers the window and shared preferences channels itself',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: channelsAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      final forwarded = <String>[];
      for (final channel in [
        'desktop_window',
        'window_manager',
        'flutter/windowsize',
        'dev.flutter.pigeon.shared_preferences_foundation.LegacyUserDefaultsApi.getAll',
        'dev.flutter.pigeon.shared_preferences_foundation.UserDefaultsApi.getValue',
      ]) {
        client.registerChannel(channel, (data) async {
          forwarded.add(channel);
          return null;
        });
      }
      try {
        final frame = await client.frames.first.timeout(
          const Duration(seconds: 15),
        );
        expect(_pixel(frame, 5, 5), _blue);
        expect(
          _pixel(frame, 400, 300),
          _green,
          reason: 'a channel call failed; the app logs which',
        );
        expect(forwarded, isEmpty);
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(channelsAssets).existsSync()
            ? false
            : 'build the runner and example/channels first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'the camera shows a picture given as its source',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      // Red on the left half, green on the right: whatever the camera's
      // aspect crops, the bars' places fall in one half each.
      final source = File(p.join(temp.path, 'source.png'))..writeAsBytesSync(
        _png(160, 120, (x, y) => x < 80 ? [220, 20, 30] : [20, 200, 40]),
      );
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: cameraAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          cameraSource: source.path,
        ),
      );
      final lines = <String>[];
      final done = Completer<void>();
      runner.stdout.listen((line) {
        final at = line.indexOf('CAMERA:');
        if (at < 0) return;
        final said = line.substring(at + 'CAMERA:'.length);
        lines.add(said);
        if ((said == 'done' || said.startsWith('error')) && !done.isCompleted) {
          done.complete();
        }
      });
      final client = await RunnerClient.connect(endpoint);
      // Each channel within 12 of the source's, as JPEG keeps it.
      bool near(String seen, List<int> want) {
        final got = seen.split(',').map(int.parse).toList();
        return [
          for (var i = 0; i < 3; i++) (got[i] - want[i]).abs() <= 12,
        ].every((close) => close);
      }

      try {
        await done.future.timeout(const Duration(seconds: 30));
        final picture = _pictureLine.firstMatch(
          lines.firstWhere((l) => l.startsWith('picture')),
        );
        expect(picture, isNotNull, reason: lines.join('\n'));
        expect(
          near(picture?[2] ?? '0,0,0', [220, 20, 30]),
          isTrue,
          reason: 'left ${picture?[2]}',
        );
        expect(
          near(picture?[3] ?? '0,0,0', [20, 200, 40]),
          isTrue,
          reason: 'right ${picture?[3]}',
        );
        File(picture?[4] ?? '').deleteSync();
        final bgra = RegExp(
          r'left=(\S+) right=(\S+)',
        ).firstMatch(lines.firstWhere((l) => l.startsWith('stream bgra8888')));
        expect(bgra?[1], '220,20,30');
        expect(bgra?[2], '20,200,40');
        expect(lines.last, 'done');
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(cameraAssets).existsSync()
            ? false
            : 'build the runner and example/camera first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  /// Runs example/camera with [source] as the camera's source; its CAMERA:
  /// lines.
  Future<List<String>> runCamera(Directory temp, String source) async {
    final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
    final runner = await RunnerProcess.start(
      RunnerLaunch(
        runnerBinary: binary ?? '',
        engineDir: engineDir ?? '',
        assets: cameraAssets,
        icuData: icu ?? '',
        endpoint: endpoint,
        cameraSource: source,
      ),
    );
    final lines = <String>[];
    final done = Completer<void>();
    runner.stdout.listen((line) {
      final at = line.indexOf('CAMERA:');
      if (at < 0) return;
      final step = line.substring(at + 'CAMERA:'.length);
      lines.add(step);
      if ((step == 'done' || step.startsWith('error')) && !done.isCompleted) {
        done.complete();
      }
    });
    final client = await RunnerClient.connect(endpoint);
    try {
      await done.future.timeout(const Duration(seconds: 30));
    } finally {
      client.shutdown();
      await client.close();
      await _expectExit(runner);
    }
    final picture = _pictureLine.firstMatch(
      lines.firstWhere((l) => l.startsWith('picture'), orElse: () => ''),
    );
    if (picture?[4] case final path?) File(path).deleteSync();
    return lines;
  }

  test(
    'the camera plays a video given as its source, in a loop',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      addTearDown(() => temp.deleteSync(recursive: true));
      final video = p.join(temp.path, 'source.mp4');
      final made = await Process.run(testVideo, [video]);
      expect(made.exitCode, 0, reason: '${made.stderr}');
      final lines = await runCamera(temp, video);
      // Each channel within 16 of the video's, as H.264 and then JPEG keep
      // them; the top half is red and green, so neither half is flipped.
      void near(String what, String? seen, List<int> want) {
        final got = (seen ?? '0,0,0').split(',').map(int.parse).toList();
        final close = [
          for (var i = 0; i < 3; i++) (got[i] - want[i]).abs() <= 16,
        ].every((each) => each);
        expect(close, isTrue, reason: '$what $seen, not $want');
      }

      final colours = RegExp(r'left=(\S+) right=(\S+)');
      final picture = colours.firstMatch(
        lines.firstWhere((l) => l.startsWith('picture')),
      );
      near('picture left', picture?[1], [220, 20, 30]);
      near('picture right', picture?[2], [20, 200, 40]);
      // The streams run past the video's end, so their later frames come
      // after it started again.
      final yuv = lines.firstWhere((l) => l.startsWith('stream yuv420'));
      expect(double.parse(yuv.split('fps=').last), inInclusiveRange(20, 40));
      for (final format in ['bgra8888', 'jpeg']) {
        final seen = colours.firstMatch(
          lines.firstWhere((l) => l.startsWith('stream $format')),
        );
        near('$format left', seen?[1], [220, 20, 30]);
        near('$format right', seen?[2], [20, 200, 40]);
      }
      expect(lines.last, 'done');
    },
    skip:
        !Platform.isWindows
            ? 'videos play on Windows only for now'
            : ready &&
                Directory(cameraAssets).existsSync() &&
                File(testVideo).existsSync()
            ? false
            : 'build the runner, raccoon_test_video and example/camera first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'elsewhere a video source is refused and the pattern stays',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      addTearDown(() => temp.deleteSync(recursive: true));
      final video = File(p.join(temp.path, 'source.mp4'))
        ..writeAsBytesSync([0, 0, 0, 0]);
      final lines = await runCamera(temp, video.path);
      // The pattern's bars: the runner said why (before it listened) and
      // kept to its pattern.
      expect(
        lines,
        contains(startsWith('stream bgra8888 planes=1 raw=1111970369 bars ok')),
      );
    },
    skip:
        Platform.isWindows
            ? 'Windows plays videos'
            : ready && Directory(cameraAssets).existsSync()
            ? false
            : 'build the runner and example/camera first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'the app sees the host\'s locales and appearance, and is resumed',
    () async {
      // A desktop embedding tells its app the host's preferred languages
      // and whether it is dark; the runner does the same after the engine
      // starts. On Linux the locales come from the environment, set here;
      // on macOS and Windows from the user's settings, read here the same
      // way.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: channelsAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
        startProcess:
            (executable, arguments) => Process.start(
              executable,
              arguments,
              environment: {'LANGUAGE': 'fr_CA:en'},
            ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!output.any((line) => line.startsWith('LIFECYCLE:')) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        // Resumed, as a desktop embedding says once the engine runs.
        expect(output, contains('LIFECYCLE:resumed'));
        // What package:raccoon reads to know it runs on Raccoon.
        expect(output, contains('RACCOON_ENDPOINT:${endpoint.uri}'));
        final locales = output.firstWhere(
          (line) => line.startsWith('LOCALES:'),
          orElse: () => 'LOCALES: none printed',
        );
        if (Platform.isMacOS) {
          expect(locales, isNot('LOCALES:'));
          // Read as apps read it, through NSUserDefaults: managed
          // preferences included, which `defaults read -g` leaves out.
          final style = await Process.run('osascript', [
            '-l',
            'JavaScript',
            '-e',
            'ObjC.import("Foundation"); '
                'var s = \$.NSUserDefaults.standardUserDefaults'
                '.stringForKey("AppleInterfaceStyle"); '
                's.isNil() ? "" : ObjC.unwrap(s)',
          ]);
          final dark = '${style.stdout}'.trim().toLowerCase() == 'dark';
          expect(output, contains('BRIGHTNESS:${dark ? 'dark' : 'light'}'));
        } else if (Platform.isWindows) {
          // The display languages and the app mode, from the user's
          // settings, as Windows apps read them.
          expect(locales, isNot('LOCALES:'));
          final mode = await Process.run('reg', [
            'query',
            r'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize',
            '/v',
            'AppsUseLightTheme',
          ]);
          final dark = RegExp(r'0x0\b').hasMatch('${mode.stdout}');
          expect(output, contains('BRIGHTNESS:${dark ? 'dark' : 'light'}'));
        } else {
          expect(locales, 'LOCALES:fr_CA,en');
          expect(output, contains('BRIGHTNESS:light'));
        }
      } finally {
        final client = await RunnerClient.connect(endpoint);
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(channelsAssets).existsSync()
            ? false
            : 'build the runner and example/channels first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'a client sets the device\'s locales, text scale, dark mode, hour format '
    'and keyboard insets',
    () async {
      // #193: in place of the host's. example/channels prints DEVICE:
      // whenever they change.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: channelsAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      final client = await RunnerClient.connect(endpoint);
      Future<String> device(bool Function(String line) wanted) async {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (DateTime.now().isBefore(deadline)) {
          for (final line in output) {
            if (line.startsWith('DEVICE:') && wanted(line)) return line;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        return 'no DEVICE: line as wanted in $output';
      }

      try {
        await client.hello.timeout(const Duration(seconds: 10));
        client.resize(800, 600, 1);
        client.setViewInsets(bottom: 300);
        client.sendSettings(
          Settings(
            locales: ['de-DE', 'zh-Hans-CN'],
            textScaleFactor: 1.5,
            dark: true,
            alwaysUse24HourFormat: true,
          ),
        );
        expect(
          await device(
            (line) => line.contains('de_DE') && line.contains('1.5'),
          ),
          'DEVICE:de_DE,zh_Hans_CN;dark;1.5;true;300.0',
        );
        // A later one replaces it whole: what it leaves unset is the
        // host's again, and the insets go with the size.
        client.sendSettings(Settings(textScaleFactor: 2));
        client.setViewInsets();
        expect(
          await device(
            (line) => line.contains(';2.0;') && line.endsWith(';0.0'),
          ),
          isNot(contains('de_DE')),
        );
        // #201: a keyboard past the view is the whole view, not a size the
        // engine refuses.
        client.resize(400, 300, 1);
        client.setViewInsets(bottom: 900);
        expect(
          await device((line) => line.endsWith(';300.0')),
          endsWith(';300.0'),
        );
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(channelsAssets).existsSync()
            ? false
            : 'build the runner and example/channels first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'a client puts the app in the background and back, and opens a link',
    () async {
      // #199: what a device's own controls send the app. example/channels
      // prints LIFECYCLE: and ROUTE: as they come.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: channelsAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      final client = await RunnerClient.connect(endpoint);
      Future<void> printed(String line) async {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!output.contains(line) && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(output, contains(line));
      }

      try {
        await client.hello.timeout(const Duration(seconds: 10));
        // The app's observer is in once it said what it is shown with.
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!output.any((line) => line.startsWith('DEVICE:')) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        client.setLifecycle('paused');
        await printed('LIFECYCLE:paused');
        client.setLifecycle('resumed');
        // Back in front: resumed again, after the pause.
        final deadline2 = DateTime.now().add(const Duration(seconds: 15));
        while (output.lastIndexOf('LIFECYCLE:resumed') <
                output.indexOf('LIFECYCLE:paused') &&
            DateTime.now().isBefore(deadline2)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          output.lastIndexOf('LIFECYCLE:resumed'),
          greaterThan(output.indexOf('LIFECYCLE:paused')),
        );
        client.openLink(Uri.parse('myapp://item/42?tab=reviews'));
        await printed('ROUTE:myapp://item/42?tab=reviews');
        // #209: the system back button.
        client.popRoute();
        await printed('BACK');
        // #212: a sensor reading, as sensors_plus' native side sends one:
        // a success envelope of a list of four doubles, each aligned to 8.
        final reading =
            ByteData(64)
              ..setUint8(0, 0)
              ..setUint8(1, 12)
              ..setUint8(2, 4);
        for (final (index, value) in [30.0, 9.81, 0.0, 1000.0].indexed) {
          reading
            ..setUint8(3 + 16 * index, 6)
            ..setFloat64(8 + 16 * index, value, Endian.little);
        }
        client.sendToApp(
          'dev.fluttercommunity.plus/sensors/accelerometer',
          reading.buffer.asUint8List(),
        );
        await printed('SENSOR:30.0');
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(channelsAssets).existsSync()
            ? false
            : 'build the runner and example/channels first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'an app a client put in the background is resumed when it goes',
    () async {
      // #201: the next client would find its frames off.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: channelsAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      Future<void> until(bool Function() done) async {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!done() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }

      final first = await RunnerClient.connect(endpoint);
      RunnerClient? second;
      try {
        await first.hello.timeout(const Duration(seconds: 10));
        await until(() => output.any((line) => line.startsWith('DEVICE:')));
        first.setLifecycle('paused');
        await until(() => output.contains('LIFECYCLE:paused'));
        await first.close();
        await until(
          () =>
              output.lastIndexOf('LIFECYCLE:resumed') >
              output.indexOf('LIFECYCLE:paused'),
        );
        expect(
          output.lastIndexOf('LIFECYCLE:resumed'),
          greaterThan(output.indexOf('LIFECYCLE:paused')),
        );
        second = await RunnerClient.connect(endpoint);
        await second.hello.timeout(const Duration(seconds: 10));
      } finally {
        (second ?? await RunnerClient.connect(endpoint)).shutdown();
        await second?.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(channelsAssets).existsSync()
            ? false
            : 'build the runner and example/channels first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  // Built beside the runner: the channels it answers itself, fed random
  // and broken input (test/channels_check.cc).
  final channelsCheck =
      binary == null
          ? ''
          : p.join(
            p.dirname(binary),
            Platform.isWindows
                ? 'raccoon_channels_check.exe'
                : 'raccoon_channels_check',
          );
  test(
    'the channels the runner answers itself hold up to random input',
    () async {
      final check = await Process.run(channelsCheck, const []);
      printOnFailure('${check.stdout}${check.stderr}');
      expect(check.exitCode, 0);
      expect('${check.stdout}', contains('CHANNELS ok'));
    },
    skip:
        File(channelsCheck).existsSync()
            ? false
            : 'build the runner\'s channels check first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

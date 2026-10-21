// Drives the real runner with the example app: frame pixels, then a tap that
// turns the box green. Skipped when the runner or its inputs are not built;
// see native/raccoon_runner/tool/render_example.sh.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:path/path.dart' as p;
import 'package:raccoon/raccoon.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

const _blue = (r: 0x1E, g: 0x88, b: 0xE5);
const _red = (r: 0xE5, g: 0x39, b: 0x35);
const _green = (r: 0x43, g: 0xA0, b: 0x47);
const _purple = (r: 0x8E, g: 0x24, b: 0xAA);

/// The colour at ([x], [y]), whichever byte order the host rasters in.
({int r, int g, int b}) _pixel(Frame frame, int x, int y) {
  final offset = y * frame.rowBytes + x * 4;
  final bytes = frame.pixels;
  return switch (frame.format) {
    PixelFormat.PIXEL_FORMAT_RGBA8888 => (
      r: bytes[offset],
      g: bytes[offset + 1],
      b: bytes[offset + 2],
    ),
    _ => (r: bytes[offset + 2], g: bytes[offset + 1], b: bytes[offset]),
  };
}

/// A JSON method-channel reply, as flutter/platform expects: a one-element
/// array holding the result.
Uint8List _jsonReply(Object? result) =>
    Uint8List.fromList(utf8.encode(jsonEncode([result])));

String? _firstExisting(Iterable<String> candidates) =>
    candidates.where((c) => c.isNotEmpty && File(c).existsSync()).firstOrNull;

void main() {
  final workspace = p.normalize(p.join(Directory.current.path, '..', '..'));
  final runnerDir = p.join(workspace, 'native', 'raccoon_runner');
  final environment = Platform.environment;
  final binary = _firstExisting([
    environment['RACCOON_RUNNER'] ?? '',
    p.join(runnerDir, 'build', 'raccoon_runner'),
  ]);
  final assets = p.join(
    runnerDir,
    'example',
    'hello',
    'build',
    'flutter_assets',
  );
  final sdk = _sdkRoot(environment);
  final revision = switch (sdk) {
    final root? => RuntimeStore.revisionOfSdk(root),
    null => null,
  };
  final engineDir =
      environment['RACCOON_ENGINE_DIR'] ??
      switch (revision) {
        final rev? => RuntimeStore.forHost(
          environment,
        ).installed(rev)?.directory,
        null => null,
      };
  final icu = _firstExisting([
    environment['RACCOON_ICU'] ?? '',
    if (sdk != null) RuntimeStore.icuDataOfSdk(sdk),
  ]);
  final ready =
      binary != null &&
      engineDir != null &&
      icu != null &&
      Directory(assets).existsSync();

  test(
    'renders the example app and reacts to a tap',
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
      try {
        final hello = await client.hello.timeout(const Duration(seconds: 10));
        expect(hello.protocolVersion, RaccoonProtocol.version);
        expect(hello.pid, runner.pid);
        expect(client.pid, runner.pid);

        final frame = await client.frames.first.timeout(
          const Duration(seconds: 15),
        );
        expect(frame.width, 800);
        expect(frame.height, 600);
        expect(frame.format, isNot(PixelFormat.PIXEL_FORMAT_UNSPECIFIED));
        expect(_pixel(frame, 5, 5), _blue);
        expect(_pixel(frame, 400, 300), _red);

        final vmService = await runner.vmServiceUri.timeout(
          const Duration(seconds: 10),
        );
        expect(vmService, startsWith('http://'));

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
        final toggled = await client.frames
            .firstWhere((f) => _pixel(f, 400, 300) == _green)
            .timeout(const Duration(seconds: 10));
        expect(_pixel(toggled, 5, 5), _blue);
        expect(
          client.sharedFrames,
          greaterThan(0),
          reason: 'frames should travel through shared buffers',
        );
      } finally {
        client.shutdown();
        await client.close();
        expect(await runner.exitCode.timeout(const Duration(seconds: 10)), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready
        ? false
        : 'build the runner and example first: $binary / $engineDir / $icu',
    timeout: const Timeout(Duration(minutes: 2)),
  );
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
        expect(await runner.exitCode.timeout(const Duration(seconds: 10)), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'frames stay right when the view shrinks after a large frame',
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
      try {
        await client.frames.first.timeout(const Duration(seconds: 15));
        for (final (w, h, ratio) in [
          (1640, 2360, 2.0),
          (395, 870, 1.0),
          (780, 1688, 2.0),
          (395, 870, 1.0),
        ]) {
          client.resize(w, h, ratio);
          final frame = await client.frames
              .firstWhere((f) => f.width == w && f.height == h)
              .timeout(const Duration(seconds: 10));
          await Future<void>.delayed(const Duration(milliseconds: 300));
          final latest = client.latestFrame ?? frame;
          expect(latest.width, w);
          expect(latest.pixels.length, latest.rowBytes * latest.height);
          expect(_pixel(latest, latest.width ~/ 2, latest.height ~/ 2), _red);
          expect(_pixel(latest, 3, 3), _blue);
        }
      } finally {
        client.shutdown();
        await client.close();
        expect(await runner.exitCode.timeout(const Duration(seconds: 10)), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  // example/channels calls desktop_window, window_manager, window_size and
  // shared_preferences_foundation at startup and shows a green box only when
  // every answer was right.
  final channelsAssets = p.join(
    runnerDir,
    'example',
    'channels',
    'build',
    'flutter_assets',
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
        expect(await runner.exitCode.timeout(const Duration(seconds: 10)), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready && Directory(channelsAssets).existsSync()
        ? false
        : 'build the runner and example/channels first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'keys reach the framework and typed characters reach a text field',
    () async {
      // example/text prints KEY:<event> for every key the framework
      // dispatches and TEXT:<value> for every change of its field.
      final textAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'text',
        'build',
        'flutter_assets',
      );
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: textAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      runner.stderr.listen(output.add);
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.frames.first.timeout(const Duration(seconds: 15));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        Future<void> key(int logical, int physical, String character) async {
          for (final kind in [KeyKind.KEY_KIND_DOWN, KeyKind.KEY_KIND_UP]) {
            client.sendKey(
              KeyEvent(
                kind: kind,
                physical: Int64(physical),
                logical: Int64(logical),
                character: kind == KeyKind.KEY_KIND_DOWN ? character : '',
                timestampMicros: Int64(DateTime.now().microsecondsSinceEpoch),
              ),
            );
            await Future<void>.delayed(const Duration(milliseconds: 60));
          }
        }

        await key(0x68, 0x0007000b, 'h');
        await key(0x69, 0x0007000c, 'i');
        // Backspace is the framework's: its shortcut deletes, not the runner.
        await key(0x100000008, 0x0007002a, '');
        await key(0x79, 0x0007001c, 'y');
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!output.any((line) => line.contains('TEXT:hy')) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final text = output
            .where((line) => line.contains('TEXT:'))
            .map((line) => line.substring(line.indexOf('TEXT:')))
            .toList();
        expect(text, ['TEXT:h', 'TEXT:hi', 'TEXT:h', 'TEXT:hy']);
        expect(
          output.where((line) => line.contains('KEY:KeyDownEvent')).length,
          4,
        );
      } finally {
        client.shutdown();
        await client.close();
        expect(await runner.exitCode.timeout(const Duration(seconds: 10)), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready &&
            Directory(
              p.join(
                p.dirname(p.dirname(p.dirname(assets))),
                'text',
                'build',
                'flutter_assets',
              ),
            ).existsSync()
        ? false
        : 'build the runner and the text example first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a second client is told who has the runner, then hung up on',
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
      final first = await RunnerClient.connect(endpoint);
      try {
        await first.hello.timeout(const Duration(seconds: 10));
        // The runner says hello before it reads the client's; give it time
        // to learn the first client's pid.
        await first.frames.first.timeout(const Duration(seconds: 15));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        Object? failure;
        RunnerClient? second;
        try {
          second = await RunnerClient.connect(endpoint);
          await second.hello.timeout(const Duration(seconds: 5));
        } on Object catch (error) {
          failure = error;
        }
        expect(failure, isA<RunnerBusy>().having((b) => b.pid, 'pid', pid));
        await second?.closed.timeout(const Duration(seconds: 5));
        await second?.close();
      } finally {
        first.shutdown();
        await first.close();
        expect(await runner.exitCode.timeout(const Duration(seconds: 10)), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'the runner stops when its parent is gone',
    () async {
      // A shell between the test and the runner stands in for the Flutter
      // tool; killing it leaves the runner without its parent.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final wrapper = File(p.join(temp.path, 'parent.sh'))
        ..writeAsStringSync('#!/bin/bash\n"$binary" "\$@" &\nwait \$!\n');
      await Process.run('chmod', ['+x', wrapper.path]);
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: wrapper.path,
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        Process.killPid(runner.pid, ProcessSignal.sigkill);
        await client.closed.timeout(const Duration(seconds: 5));
      } finally {
        await client.close();
        await runner.exitCode.timeout(const Duration(seconds: 10));
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready && !Platform.isWindows
        ? false
        : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );
}

/// The SDK behind `FLUTTER_ROOT`, else behind the `flutter` on the PATH.
String? _sdkRoot(Map<String, String> environment) {
  if (environment['FLUTTER_ROOT'] case final root? when root.isNotEmpty) {
    return root;
  }
  return RuntimeStore.sdkRootOnPath();
}

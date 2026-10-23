// Drives the real runner with the example app: frame pixels, then a tap that
// turns the box green. Skipped when the runner or its inputs are not built;
// see native/raccoon_runner/tool/render_example.sh.

import 'dart:async';
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
    p.join(
      runnerDir,
      'build',
      Platform.isWindows ? 'raccoon_runner.exe' : 'raccoon_runner',
    ),
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
        final rev? =>
          RuntimeStore.forHost(environment).installed(rev)?.directory,
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
        // A Windows socket carries no handles, so frames ride inline there.
        expect(
          client.sharedFrames,
          Platform.isWindows ? 0 : greaterThan(0),
          reason: 'frames should travel through shared buffers where they can',
        );
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready
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
        expect(await _exitCode(runner), 0);
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
          // Inside the box but above its label: where a glyph lands differs
          // between rasterizers by a pixel.
          expect(
            _pixel(
              latest,
              latest.width ~/ 2,
              latest.height ~/ 2 - (45 * ratio).round(),
            ),
            _red,
          );
          expect(_pixel(latest, 3, 3), _blue);
        }
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
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
        expect(await _exitCode(runner), 0);
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
        final text =
            output
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
        expect(await _exitCode(runner), 0);
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
        expect(await _exitCode(runner), 0);
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
      // tool; killing it leaves the runner without its parent. On Windows
      // the shell is cmd.exe, which waits for the runner as bash does.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final File wrapper;
      if (Platform.isWindows) {
        wrapper = File(p.join(temp.path, 'parent.cmd'))
          ..writeAsStringSync('@"$binary" %*\r\n');
      } else {
        wrapper = File(p.join(temp.path, 'parent.sh'))
          ..writeAsStringSync('#!/bin/bash\n"$binary" "\$@" &\nwait \$!\n');
        await Process.run('chmod', ['+x', wrapper.path]);
      }
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
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'a composing client mirrors the active field and types through it',
    () async {
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
      final client = await RunnerClient.connect(endpoint, composes: true);
      try {
        // The field has autofocus: its state arrives as it becomes active.
        final field = await client.textFields
            .firstWhere((field) => field.active)
            .timeout(const Duration(seconds: 15));
        expect(field.text, '');
        expect(field.multiline, isFalse);
        Future<void> texts(List<String> expected) async {
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          while (!output.any(
                (line) => line.contains('TEXT:${expected.last}'),
              ) &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(
            output
                .where((line) => line.contains('TEXT:'))
                .map((line) => line.substring(line.indexOf('TEXT:'))),
            [for (final text in expected) 'TEXT:$text'],
          );
        }

        // The host's input method composes "tiế", then commits "tiếng".
        client.sendTextEditing(
          TextEditing(
            text: 'tiế',
            selectionBase: 3,
            selectionExtent: 3,
            composingBase: 0,
            composingExtent: 3,
          ),
        );
        await texts(['tiế']);
        client.sendTextEditing(
          TextEditing(
            text: 'tiếng',
            selectionBase: 5,
            selectionExtent: 5,
            composingBase: -1,
            composingExtent: -1,
          ),
        );
        await texts(['tiế', 'tiếng']);
        final mirrored = await client.textFields
            .firstWhere((field) => field.text == 'tiếng')
            .timeout(const Duration(seconds: 5));
        expect(mirrored.selectionBase, 5);
        expect(mirrored.composingBase, -1);

        // A character key types nothing for a composing client; Backspace is
        // still the framework's.
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

        await key(0x78, 0x0007001b, 'x');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await key(0x100000008, 0x0007002a, '');
        await texts(['tiế', 'tiếng', 'tiến']);
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
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
        expect(await _exitCode(runner), 0);
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
    'a data directory keeps the app\'s files apart from other apps\'',
    () async {
      // On Linux, path_provider and shared_preferences are Dart only and put
      // every app hosted by one executable under the same XDG directory; the
      // runner points XDG_DATA_HOME into the app's data directory instead.
      // example/channels prints what it sees.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final dataDir = p.join(temp.path, 'data');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: channelsAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          dataDir: dataDir,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!output.any((line) => line.startsWith('XDG_DATA_HOME:')) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          output,
          contains('XDG_DATA_HOME:${p.join(dataDir, 'xdg', 'data')}'),
        );
      } finally {
        final client = await RunnerClient.connect(endpoint);
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch (ready && Directory(channelsAssets).existsSync()) {
      false => 'build the runner and example/channels first',
      // path_provider_windows asks the shell, which no variable moves.
      true when Platform.isWindows => 'no XDG directories on Windows',
      true => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  // example/plugins/echo is a native plugin the runner's build compiles:
  // against its own flutter_linux library on Linux, as a framework against
  // the SDK's FlutterMacOS on macOS. example/plugins_app calls it.
  final pluginLibrary =
      binary == null
          ? ''
          : p.joinAll([
            p.dirname(binary),
            'example_plugins',
            'echo',
            ...switch (Platform.operatingSystem) {
              'macos' => ['raccoon_echo.framework', 'raccoon_echo'],
              'windows' => ['raccoon_echo_plugin.dll'],
              _ => ['libraccoon_echo_plugin.so'],
            },
          ]);
  // macOS plugins link FlutterMacOS; the manifest names the SDK's, which
  // the runner opens first.
  final flutterFramework =
      sdk == null || !Platform.isMacOS
          ? null
          : p.join(
            sdk,
            'bin',
            'cache',
            'artifacts',
            'engine',
            'darwin-x64',
            'FlutterMacOS.xcframework',
            'macos-arm64_x86_64',
            'FlutterMacOS.framework',
            'FlutterMacOS',
          );
  final pluginsAppAssets = p.join(
    p.dirname(p.dirname(p.dirname(assets))),
    'plugins_app',
    'build',
    'flutter_assets',
  );
  test(
    'a native plugin loaded into the runner answers the app',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final manifest = File(p.join(temp.path, 'plugins.json'))
        ..writeAsStringSync(
          jsonEncode({
            if (flutterFramework != null) 'flutter_framework': flutterFramework,
            'plugins': [
              _pluginEntry('raccoon_echo', pluginLibrary, 'RaccoonEchoPlugin'),
            ],
          }),
        );
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: pluginsAppAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          plugins: manifest.path,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!output.any((line) => line.startsWith('ECHO:')) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        // The plugin answers from GLib's main loop on Linux, the main queue on
        // macOS, the platform thread's messages on Windows: the runner turns
        // the plugins' main loop.
        expect(output, contains('ECHO:echo: hello'));
      } finally {
        final client = await RunnerClient.connect(endpoint);
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready &&
                File(pluginLibrary).existsSync() &&
                Directory(pluginsAppAssets).existsSync()
            ? false
            : 'build the runner with plugins and example/plugins_app first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'an FFI plugin\'s framework is opened for Dart and reported loaded',
    () async {
      // macOS: no class to register, only a framework whose symbols Dart
      // finds in the process or by name. The echo framework stands in.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final manifest = File(p.join(temp.path, 'plugins.json'))
        ..writeAsStringSync(
          jsonEncode({
            'flutter_framework': flutterFramework,
            'plugins': [
              {'name': 'echo_ffi', 'library': pluginLibrary, 'ffi': true},
            ],
          }),
        );
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: pluginsAppAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          plugins: manifest.path,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        final plugins = await client.plugins.first.timeout(
          const Duration(seconds: 10),
        );
        expect(plugins.plugins.single.state, PluginState.PLUGIN_STATE_LOADED);
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isMacOS
            ? 'FFI entries are macOS manifests'
            : ready &&
                File(pluginLibrary).existsSync() &&
                Directory(pluginsAppAssets).existsSync()
            ? false
            : 'build the runner with plugins and example/plugins_app first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'the runner tells a client what became of the plugins',
    () async {
      // The manifest carries the helper's word on what never got as far as a
      // library; the runner adds its own on what it loaded, and sends the
      // lot after Hello.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final manifest = File(p.join(temp.path, 'plugins.json'))
        ..writeAsStringSync(
          jsonEncode({
            if (flutterFramework != null) 'flutter_framework': flutterFramework,
            'plugins': [
              _pluginEntry('raccoon_echo', pluginLibrary, 'RaccoonEchoPlugin'),
              _pluginEntry(
                'nowhere',
                p.join(temp.path, 'libnowhere_plugin.so'),
                'NowherePlugin',
              ),
            ],
            'status': [
              {
                'name': 'firebase_core',
                'state': 'no_host',
                'detail': 'no Linux implementation',
              },
              {
                'name': 'desktop_window',
                'state': 'built_in',
                'detail': 'the runner answers it',
              },
            ],
          }),
        );
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: pluginsAppAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          plugins: manifest.path,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      // The runner's stderr from before the first frame, relayed.
      final logs = <String>[];
      final logged = client.messages
          .where((m) => m.hasLog())
          .listen((m) => logs.add(m.log.message));
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        final plugins = await client.plugins.first.timeout(
          const Duration(seconds: 10),
        );
        final byName = {for (final s in plugins.plugins) s.name: s};
        expect(byName['raccoon_echo']?.state, PluginState.PLUGIN_STATE_LOADED);
        expect(byName['nowhere']?.state, PluginState.PLUGIN_STATE_FAILED);
        expect(byName['nowhere']?.detail, contains('libnowhere_plugin.so'));
        expect(
          byName['firebase_core']?.state,
          PluginState.PLUGIN_STATE_NO_HOST,
        );
        expect(
          byName['desktop_window']?.state,
          PluginState.PLUGIN_STATE_BUILT_IN,
        );
        expect(client.latestPlugins, plugins);
        if (Platform.isMacOS) {
          // FlutterMacOS shares classes with the engine library; the
          // runtime's line for each is left out, one line says so.
          await Future<void>.delayed(const Duration(seconds: 1));
          expect(
            logs.where((l) => l.contains('is implemented in both')),
            isEmpty,
          );
          expect(logs, contains(contains('FlutterMacOS shares')));
        }
      } finally {
        await logged.cancel();
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready &&
                File(pluginLibrary).existsSync() &&
                Directory(pluginsAppAssets).existsSync()
            ? false
            : 'build the runner with plugins and example/plugins_app first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a plugin\'s texture draws through the renderer',
    () async {
      // The echo plugin registers a 64 by 64 pixel-buffer texture, orange;
      // example/plugins_app draws it full screen. The frame a client reads
      // back is then orange: the texture went through the GPU renderer (GL
      // on Linux, Metal on macOS) and the compositor. The software renderer
      // takes no textures.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final manifest = File(p.join(temp.path, 'plugins.json'))
        ..writeAsStringSync(
          jsonEncode({
            if (flutterFramework != null) 'flutter_framework': flutterFramework,
            'plugins': [
              _pluginEntry('raccoon_echo', pluginLibrary, 'RaccoonEchoPlugin'),
            ],
          }),
        );
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: pluginsAppAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          plugins: manifest.path,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!output.any((line) => line.startsWith('TEXTURE:')) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        if (runner.renderer != 'gl' && runner.renderer != 'metal') {
          printOnFailure(
            'software renderer, no textures: ${output.join('\n')}',
          );
          // Linux's registrar refuses the texture. FlutterMacOS's has no way
          // to: the id comes back and nothing draws.
          if (!Platform.isMacOS) {
            expect(output, contains(startsWith('TEXTURE:error')));
          }
          return;
        }
        expect(output, contains(startsWith('TEXTURE:')));
        final orange = await client.frames
            .firstWhere(
              (f) => _pixel(f, 400, 300) == (r: 0xFF, g: 0x8C, b: 0x00),
            )
            .timeout(const Duration(seconds: 15));
        expect(_pixel(orange, 5, 5), (r: 0xFF, g: 0x8C, b: 0x00));
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready &&
                File(pluginLibrary).existsSync() &&
                Directory(pluginsAppAssets).existsSync()
            ? false
            : 'build the runner with plugins and example/plugins_app first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  // Built beside the runner on macOS: a GPU socket client that takes the
  // ring's surfaces by Mach port and checks them.
  final portCheck =
      binary == null ? '' : p.join(p.dirname(binary), 'raccoon_gpu_port_check');
  test(
    'on macOS the GPU socket hands out surfaces by Mach port, not global IDs',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final spinAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'spin',
        'build',
        'flutter_assets',
      );
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: spinAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint, gpuBuffers: true);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        final set = await client.gpuBufferSets.first.timeout(
          const Duration(seconds: 10),
        );
        // Buffers go back as frames come, so the ring keeps turning.
        Frame? previous;
        final frames = client.frames.listen((frame) {
          final last = previous;
          if (last != null && last.inGpuBuffer) {
            client.releaseGpuBuffer(last.gpuGeneration, last.bufferIndex);
          }
          previous = frame;
        });
        final check = await Process.run(portCheck, [set.socket]);
        await frames.cancel();
        printOnFailure('${check.stdout}${check.stderr}');
        expect(check.exitCode, 0);
        expect('${check.stdout}', contains('PORTS ok'));
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isMacOS
            ? 'Mach ports are macOS'
            : ready && File(portCheck).existsSync()
            ? false
            : 'build the runner and its port check first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  // Built beside the runner on Windows: a GPU socket client that opens the
  // ring's textures by their shared handles and checks the frame in them.
  final handleCheck =
      binary == null
          ? ''
          : p.join(p.dirname(binary), 'raccoon_gpu_handle_check.exe');
  test(
    'on Windows a client opens the ring by its shared handles and finds the frame',
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
      final client = await RunnerClient.connect(endpoint, gpuBuffers: true);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        // Without a Vulkan device (a CI machine) the runner rasterizes in
        // software and offers no textures: nothing to open.
        if (runner.renderer != 'vulkan') {
          printOnFailure('renderer ${runner.renderer}, no shared textures');
          return;
        }
        final set = await client.gpuBufferSets.first.timeout(
          const Duration(seconds: 10),
        );
        await client.frames
            .firstWhere((frame) => frame.inGpuBuffer)
            .timeout(const Duration(seconds: 10));
        final check = await Process.run(handleCheck, [set.socket]);
        printOnFailure('${check.stdout}${check.stderr}');
        expect(check.exitCode, 0);
        expect('${check.stdout}', contains('HANDLES ok'));
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isWindows
            ? 'shared D3D11 textures are Windows'
            : ready && File(handleCheck).existsSync()
            ? false
            : 'build the runner and its handle check first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a client that imports GPU buffers gets frames as buffer indices and their descriptors on the GPU socket',
    () async {
      // The spin example animates, so frames keep coming.
      final spinAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'spin',
        'build',
        'flutter_assets',
      );
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: spinAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint, gpuBuffers: true);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        // Only a renderer that exports offers them; otherwise frames come by
        // readback and the test has nothing to check.
        final GpuBuffers set;
        try {
          set = await client.gpuBufferSets.first.timeout(
            const Duration(seconds: 5),
          );
        } on TimeoutException {
          final frame = await client.frames.first.timeout(
            const Duration(seconds: 10),
          );
          expect(frame.inGpuBuffer, isFalse);
          printOnFailure('no GPU buffers offered: ${client.latestGpuBuffers}');
          return;
        }
        expect(set.count, 4);
        expect(set.generation, greaterThan(0));
        expect(set.width, 800);
        expect(set.height, 600);
        expect(set.strides, hasLength(4));
        expect(set.socket, p.join(temp.path, 'runner.gpu'));

        // Frames are indices now, no pixels; giving them back keeps them
        // coming past the ring's size.
        final frames = <Frame>[];
        final done = Completer<void>();
        // Later, buffers go back over the GPU socket instead.
        late RawSocket gpuSocket;
        var releaseOnSocket = false;
        final socketFrames = <Frame>[];
        final doneOnSocket = Completer<void>();
        // Last, buffers are held: the ring starves, then the GPU socket's
        // client goes away and they are the runner's again.
        var hold = false;
        final starved = Completer<void>();
        final freed = Completer<void>();
        var afterStarving = 0;
        final subscription = client.frames.listen((frame) {
          frames.add(frame);
          if (hold) {
            if (!frame.inGpuBuffer && !starved.isCompleted) starved.complete();
            if (frame.inGpuBuffer && starved.isCompleted) afterStarving++;
            if (afterStarving >= 2 && !freed.isCompleted) freed.complete();
            return;
          }
          if (frame.inGpuBuffer) {
            if (releaseOnSocket) {
              socketFrames.add(frame);
              gpuSocket.write(_release(frame.gpuGeneration, frame.bufferIndex));
              if (socketFrames.length >= 8 && !doneOnSocket.isCompleted) {
                doneOnSocket.complete();
              }
            } else {
              client.releaseGpuBuffer(frame.gpuGeneration, frame.bufferIndex);
            }
          }
          if (frames.length >= 8 && !done.isCompleted) done.complete();
        });
        await done.future.timeout(const Duration(seconds: 15));
        expect(frames.where((f) => f.inGpuBuffer), isNotEmpty);
        expect(
          frames.where((f) => f.inGpuBuffer).every((f) => f.pixels.isEmpty),
          isTrue,
        );
        expect(
          frames
              .where((f) => f.inGpuBuffer)
              .map((f) => f.bufferIndex)
              .toSet()
              .length,
          greaterThan(1),
        );

        // The GPU socket serves the same description: on Linux with one
        // descriptor per buffer riding along, on macOS with the surfaces'
        // IDs after the pairs and nothing riding along, on Windows with the
        // textures' shared handles there instead.
        gpuSocket = await RawSocket.connect(
          InternetAddress(set.socket, type: InternetAddressType.unix),
          0,
        );
        final handles = <ResourceHandle>[];
        final bytes = <int>[];
        final described = Completer<void>();
        gpuSocket.listen((event) {
          if (event != RawSocketEvent.read) return;
          if (Platform.isWindows) {
            bytes.addAll(gpuSocket.read() ?? const []);
          } else {
            final message = gpuSocket.readMessage();
            if (message == null) return;
            bytes.addAll(message.data);
            for (final control in message.controlMessages) {
              handles.addAll(control.extractHandles());
            }
          }
          final whole = MessageUnframer()
              .add(Uint8List.fromList(bytes))
              .any((m) => String.fromCharCodes(m.sublist(0, 4)) == 'RGPU');
          if (whole &&
              (!Platform.isLinux || handles.length >= 4) &&
              !described.isCompleted) {
            described.complete();
          }
        });
        await described.future.timeout(const Duration(seconds: 10));
        final messages =
            MessageUnframer().add(Uint8List.fromList(bytes)).toList();
        expect(messages, isNotEmpty);
        // A fixed layout, so a native client needs no protobuf.
        final data = ByteData.sublistView(messages.first);
        expect(String.fromCharCodes(messages.first.sublist(0, 4)), 'RGPU');
        expect(data.getUint32(4, Endian.little), set.generation);
        expect(data.getUint32(8, Endian.little), 4);
        expect(data.getUint32(12, Endian.little), set.width);
        expect(data.getUint32(16, Endian.little), set.height);
        expect(data.getUint32(20, Endian.little), set.fourcc);
        if (!Platform.isLinux) {
          expect(messages.first.length, 32 + 4 * 8 + 4 * 4);
          final ids = [
            for (var i = 0; i < 4; i++)
              data.getUint32(32 + 4 * 8 + i * 4, Endian.little),
          ];
          expect(ids.toSet(), hasLength(4));
          expect(ids, everyElement(isNot(0)));
          expect(handles, isEmpty);
        } else {
          expect(messages.first.length, 32 + 4 * 8);
          expect(handles.length, greaterThanOrEqualTo(4));
        }

        // Where EGL has native fences, each frame's fence comes ahead of it:
        // 'RFEN', generation, index, one descriptor riding along. Metal
        // names a frame once it is drawn instead, so there are none.
        List<Uint8List> fences() =>
            MessageUnframer()
                .add(Uint8List.fromList(bytes))
                .where((m) => String.fromCharCodes(m.sublist(0, 4)) == 'RFEN')
                .toList();
        final deadline = DateTime.now().add(
          Platform.isMacOS ? Duration.zero : const Duration(seconds: 3),
        );
        while (fences().isEmpty && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        final fenced = fences();
        final handleCount = handles.length;
        if (fenced.isEmpty) {
          printOnFailure('no fences from this renderer');
        } else {
          expect(fenced.every((m) => m.length == 12), isTrue);
          expect(
            fenced
                .map((m) => ByteData.sublistView(m).getUint32(4, Endian.little))
                .toSet(),
            {set.generation},
          );
          expect(handleCount, 4 + fenced.length);
        }

        // Buffers can be given back on this socket too: 'RREL', generation,
        // index, fenced; frames keep coming past the ring's size.
        releaseOnSocket = true;
        await doneOnSocket.future.timeout(const Duration(seconds: 15));
        expect(
          socketFrames.map((f) => f.bufferIndex).toSet().length,
          greaterThan(1),
        );

        // Held buffers starve the ring into readback; once the client on
        // the GPU socket is gone, the runner takes them all back.
        hold = true;
        await starved.future.timeout(const Duration(seconds: 15));
        await gpuSocket.close();
        await freed.future.timeout(const Duration(seconds: 15));
        await subscription.cancel();
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  // example/no_plugin calls a Pigeon channel nobody serves in main(), before
  // runApp, and dies of the null reply; example/no_plugin_late draws first,
  // then calls a method channel nobody serves, and again on every tap.
  final noPluginAssets = p.join(
    runnerDir,
    'example',
    'no_plugin',
    'build',
    'flutter_assets',
  );
  final noPluginLateAssets = p.join(
    runnerDir,
    'example',
    'no_plugin_late',
    'build',
    'flutter_assets',
  );
  const pigeonChannel =
      'dev.flutter.pigeon.absent_plugin.AbsentHostApi.initialize';
  const lateChannel = 'plugins.flutter.io/absent_plugin';
  const orange = (r: 0xFB, g: 0x8C, b: 0x00);
  const grey = (r: 0x9E, g: 0x9E, b: 0x9E);

  /// How long the app took for its call, from what it printed last with
  /// [prefix], such as `NO_PLUGIN:null after 3 ms`.
  int? replyMillis(Iterable<String> lines, String prefix) {
    final printed = lines.where((line) => line.contains(prefix)).lastOrNull;
    if (printed == null) return null;
    final match = RegExp(r'after (\d+) ms').firstMatch(printed);
    return int.tryParse(match?.group(1) ?? '');
  }

  test(
    'a plugin nobody serves before runApp gets no reply at once, and the '
    'client is told why the app stopped',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: noPluginAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final stderr = <String>[];
      runner.stderr.listen(stderr.add);
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        final failure = await client.startupFailures
            .firstWhere((failure) => failure != null)
            .timeout(const Duration(seconds: 15));
        expect(
          failure?.exception,
          'PlatformException(channel-error, Unable to establish connection '
          'on channel: "$pigeonChannel"., null, null)',
        );
        expect(failure?.stackTrace.first, startsWith('#0      main'));
        expect(failure?.channels, [pigeonChannel]);
        // The reply came back empty, and at once: nothing waited on a bound.
        final millis = replyMillis(client.startupLog, 'NO_PLUGIN:null');
        expect(millis, isNotNull, reason: client.startupLog.join('\n'));
        expect(millis, lessThan(1000));
        // The runner said so under its own name, for the tool's output.
        expect(
          client.startupLog.any(
            (line) => line.startsWith(
              'raccoon_runner: nothing answered $pigeonChannel (',
            ),
          ),
          isTrue,
        );
        expect(client.latestFrame, isNull);
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(noPluginAssets).existsSync()
            ? false
            : 'build the runner and example/no_plugin first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a plugin nobody serves after the first frame fails the call and the '
    'app goes on drawing',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: noPluginLateAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      runner.stderr.listen(output.add);
      final client = await RunnerClient.connect(endpoint);
      try {
        final failed = await client.frames
            .firstWhere((frame) => _pixel(frame, 400, 300) == orange)
            .timeout(const Duration(seconds: 15));
        expect(_pixel(failed, 5, 5), _blue);
        expect(client.startupFailure, isNull);
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (replyMillis(output, 'NO_PLUGIN_LATE:') == null &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          output.where((line) => line.contains('NO_PLUGIN_LATE:')).first,
          contains('NO_PLUGIN_LATE:MissingPluginException'),
        );
        expect(replyMillis(output, 'NO_PLUGIN_LATE:'), lessThan(1000));
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(noPluginLateAssets).existsSync()
            ? false
            : 'build the runner and example/no_plugin_late first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a reply the client never sends is answered empty after the bound',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: noPluginLateAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      runner.stderr.listen(output.add);
      final client = await RunnerClient.connect(endpoint);
      // A client that takes the call and never answers.
      final asked = <DateTime>[];
      client.registerChannel(lateChannel, (data) {
        asked.add(DateTime.now());
        return Completer<Uint8List?>().future;
      });
      try {
        // The call at the first frame went out before or after the client
        // took the channel; either way it fails in the end.
        await client.frames
            .firstWhere((frame) => _pixel(frame, 400, 300) == orange)
            .timeout(const Duration(seconds: 20));
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
            .firstWhere((frame) => _pixel(frame, 400, 300) == grey)
            .timeout(const Duration(seconds: 10));
        final tapped = DateTime.now();
        await client.frames
            .firstWhere((frame) => _pixel(frame, 400, 300) == orange)
            .timeout(const Duration(seconds: 15));
        final waited = DateTime.now().difference(tapped);
        final printed = DateTime.now().add(const Duration(seconds: 5));
        while (output.where((line) => line.contains('NO_PLUGIN_LATE:')).length <
                2 &&
            DateTime.now().isBefore(printed)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(asked, isNotEmpty);
        expect(waited, greaterThan(const Duration(seconds: 3)));
        expect(waited, lessThan(const Duration(seconds: 10)));
        expect(
          replyMillis(output, 'NO_PLUGIN_LATE:MissingPluginException'),
          greaterThanOrEqualTo(4000),
        );
        expect(
          output.where(
            (line) =>
                line ==
                'raccoon_runner: nothing answered $lateChannel (the client '
                    'did not answer in 5 s); the app sees no plugin',
          ),
          hasLength(1),
          reason: 'once per channel',
        );
        expect(client.startupFailure, isNull);
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(noPluginLateAssets).existsSync()
            ? false
            : 'build the runner and example/no_plugin_late first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

/// A release of buffer [index] of [generation] as the GPU socket takes it,
/// framed, without a fence.
Uint8List _release(int generation, int index) {
  final payload =
      ByteData(16)
        ..setUint32(4, generation, Endian.little)
        ..setUint32(8, index, Endian.little)
        ..setUint32(12, 0, Endian.little);
  payload.buffer.asUint8List().setAll(0, 'RREL'.codeUnits);
  return MessageFraming.frame(payload.buffer.asUint8List());
}

/// The runner's exit code, waiting up to 10 s. One still running by then has
/// its threads sampled into the failure (macOS's `sample`) and is killed, so
/// a hang on CI says where it was.
Future<int?> _exitCode(RunnerProcess runner) async {
  try {
    return await runner.exitCode.timeout(const Duration(seconds: 10));
  } on TimeoutException {
    if (Platform.isMacOS) {
      final report = p.join(
        Directory.systemTemp.path,
        'runner-${runner.pid}.sample',
      );
      final sampled = await Process.run('sample', [
        '${runner.pid}',
        '2',
        '-file',
        report,
      ]);
      printOnFailure(
        'the runner did not exit; its threads:\n${sampled.stdout}',
      );
    }
    runner.kill();
    return null;
  }
}

/// A manifest entry for a plugin of [name] in [library]: registered by its
/// `<name>_plugin_register_with_registrar` on Linux, by [pluginClass] on
/// macOS, by `<pluginClass>RegisterWithRegistrar` on Windows.
Map<String, String> _pluginEntry(
  String name,
  String library,
  String pluginClass,
) => {
  'name': name,
  'library': library,
  if (Platform.isMacOS)
    'class': pluginClass
  else if (Platform.isWindows)
    'symbol': '${pluginClass}RegisterWithRegistrar'
  else
    'symbol': '${name}_plugin_register_with_registrar',
};

/// The SDK behind `FLUTTER_ROOT`, else behind the `flutter` on the PATH.
String? _sdkRoot(Map<String, String> environment) {
  if (environment['FLUTTER_ROOT'] case final root? when root.isNotEmpty) {
    return root;
  }
  return RuntimeStore.sdkRootOnPath();
}

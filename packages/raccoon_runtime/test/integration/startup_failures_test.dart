// Drives the real runner: a run that cannot start says why and ends: no engine,
// no kernel, no socket, another Flutter. Skipped when the runner or its inputs
// are not built; see native/raccoon_runner/tool/render_example.sh. What the
// files share is in test/support/runner_fixture.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

import '../support/runner_fixture.dart';

// The fixture's helpers, by the names these tests have always used.
const _exitCode = runnerExitCode;
const _runHelper = runHelper;

void main() {
  final RunnerFixture(
    :runnerDir,
    :environment,
    :binary,
    :assets,
    :sdk,
    :engineDir,
    :icu,
    :ready,
  ) = RunnerFixture();
  // #119: an engine that can't be downloaded stops the run with a word on
  // why, not with the runner's usage text.
  test(
    'a run whose engine can\'t be downloaded says so',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_offline');
      final environment = {
        'RACCOON_RUNNER': binary!,
        if (sdk != null) 'FLUTTER_ROOT': sdk,
        'XDG_DATA_HOME': p.join(temp.path, 'data'),
        'XDG_RUNTIME_DIR': temp.path,
        'TMPDIR': '${temp.path}/',
        // Where Windows puts the sockets.
        'TMP': temp.path,
        // No engine cached, and no way to fetch one.
        'RACCOON_ENGINE_CACHE': p.join(temp.path, 'engines'),
        'https_proxy': 'http://127.0.0.1:9',
        'HTTPS_PROXY': 'http://127.0.0.1:9',
      };
      try {
        final install = await _runHelper(runnerDir, [
          'install',
          assets,
          'offline',
        ], environment);
        expect(install.exitCode, 0, reason: '${install.stderr}');
        final run = await _runHelper(runnerDir, [
          'run',
          'offline',
        ], environment).timeout(const Duration(seconds: 60));
        expect(run.exitCode, isNot(0));
        expect(
          '${run.stderr}',
          contains('could not download the Flutter engine'),
        );
        expect('${run.stderr}', isNot(contains('usage:')));

        // A runner that isn't there says so too, the engine found as usual.
        final missing = await _runHelper(
          runnerDir,
          ['run', 'offline'],
          {
            for (final MapEntry(:key, :value) in environment.entries)
              if (!key.toLowerCase().contains('proxy') &&
                  key != 'RACCOON_ENGINE_CACHE')
                key: value,
            'RACCOON_RUNNER': p.join(temp.path, 'no_runner'),
          },
        ).timeout(const Duration(seconds: 60));
        expect(missing.exitCode, isNot(0));
        expect('${missing.stderr}', contains('no runner at'));

        // And an app that was never installed.
        final absent = await _runHelper(runnerDir, [
          'run',
          'never_installed',
        ], environment).timeout(const Duration(seconds: 60));
        expect(absent.exitCode, isNot(0));
        expect(
          '${absent.stderr}',
          contains('never_installed is not installed'),
        );
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch (ready) {
      false => 'build the runner and example first',
      true => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  // #347: a bundle without its kernel failed as "FlutterEngineRun failed
  // with 2", the reason only in the engine's own words.
  test(
    'a bundle without its kernel says so',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_no_kernel');
      addTearDown(() => temp.deleteSync(recursive: true));
      for (final entity in Directory(assets).listSync(recursive: true)) {
        final target = p.join(temp.path, p.relative(entity.path, from: assets));
        if (entity is File && p.basename(entity.path) != 'kernel_blob.bin') {
          File(target).parent.createSync(recursive: true);
          entity.copySync(target);
        }
      }
      final result = await Process.run(binary!, [
        'render',
        '--engine-dir',
        engineDir!,
        '--assets',
        temp.path,
        '--icu',
        icu!,
        '--out',
        p.join(temp.path, 'frame.ppm'),
      ]);
      expect(result.exitCode, isNot(0));
      expect('${result.stderr}', contains('no kernel_blob.bin in'));
    },
    skip:
        ready
            ? false
            : 'build the runner and example first: $binary / $engineDir / $icu',
  );
  test(
    'a socket it cannot listen on ends the runner cleanly',
    () async {
      // By then the engine runs: it goes down before the runner returns,
      // rather than under its threads.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final socket = p.join(temp.path, '${'s' * 200}.sock');
      final runner = await Process.start(binary ?? '', [
        'serve',
        '--engine-dir',
        engineDir ?? '',
        '--assets',
        assets,
        '--icu',
        icu ?? '',
        '--socket',
        socket,
      ]);
      final errors = <String>[];
      runner.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(errors.add);
      unawaited(runner.stdout.drain<void>());
      try {
        final code = await runner.exitCode.timeout(const Duration(seconds: 15));
        expect(code, 1, reason: errors.join('\n'));
        expect(errors.join('\n'), isNot(contains('stopped')));
      } finally {
        runner.kill();
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );
  // #408: an app installed before a Flutter upgrade. Its kernel's format
  // version made 1 is what the engine sees, whichever engine it is.
  final otherFlutter = RegExp(
    r'^Built with another Flutter \(Invalid kernel binary format version '
    r'\(expected \d+, found 1\)\)$',
  );
  const fix = 'flutter run -d raccoon builds it again';
  bool saysNotStarted(String line) =>
      line.startsWith('🦝 the app did not start: built with another Flutter (');
  test(
    'an app built with another Flutter: the client is told why and what '
    'fixes it, and the run ends with 1 once it goes (#408)',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final stale = _otherFlutterBundle(assets, temp);
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: stale,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      int? code;
      try {
        final failure = await client.startupFailures
            .firstWhere((failure) => failure != null)
            .timeout(const Duration(seconds: 15));
        expect(failure?.exception, matches(otherFlutter));
        expect(failure?.hints, [fix]);
        expect(client.startupLog.where(saysNotStarted), hasLength(1));
        expect(client.latestFrame, isNull);
        // The runner stays while its client shows why, as for an app that
        // died in main().
        final gone = await runner.exitCode
            .then((_) => true)
            .timeout(const Duration(seconds: 1), onTimeout: () => false);
        expect(gone, isFalse);
      } finally {
        client.shutdown();
        await client.close();
        code = await _exitCode(runner);
        temp.deleteSync(recursive: true);
      }
      expect(code, 1, reason: 'an app that never started is a run that failed');
    },
    skip: ready ? false : 'build the runner and example/hello first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'an app built with another Flutter fails launchBundle at once with the '
    "runner's words; with no client the run ends by itself (#408)",
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      try {
        final stale = _otherFlutterBundle(assets, temp);
        final clock = Stopwatch()..start();
        final launch = RaccoonTestDevice.launchBundle(
          stale,
          runnerBinary: binary,
          engineDir: engineDir,
          icuData: icu,
        );
        final exited = await launch.then<Object>((device) async {
          await device.stop();
          return device;
        }, onError: (Object error) => error);
        expect(exited, isA<RunnerExited>());
        exited as RunnerExited;
        expect(exited.exitCode, 1);
        expect(
          exited.lastLines.where(saysNotStarted),
          hasLength(1),
          reason: exited.lastLines.join('\n'),
        );
        expect(clock.elapsed, lessThan(const Duration(seconds: 10)));

        // Not headless and nobody comes: it waits for a host a while, then
        // ends rather than sitting with no frame.
        final endpoint = UnixSocketEndpoint(p.join(temp.path, 'alone.sock'));
        final runner = await RunnerProcess.start(
          RunnerLaunch(
            runnerBinary: binary ?? '',
            engineDir: engineDir ?? '',
            assets: stale,
            icuData: icu ?? '',
            endpoint: endpoint,
          ),
        );
        final alone = await runner.exited.timeout(const Duration(seconds: 20));
        expect(alone.exitCode, 1);
        expect(
          alone.lastLines.where(saysNotStarted),
          hasLength(1),
          reason: alone.lastLines.join('\n'),
        );
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example/hello first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'render of an app built with another Flutter says why and ends at once, '
    'not at its timeout',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      addTearDown(() => temp.deleteSync(recursive: true));
      final stale = _otherFlutterBundle(assets, temp);
      final out = p.join(temp.path, 'frame.ppm');
      final clock = Stopwatch()..start();
      // UTF-8 whatever the host's code page, for the 🦝 on Windows.
      final result = await Process.run(
        binary!,
        [
          'render',
          '--engine-dir',
          engineDir!,
          '--assets',
          stale,
          '--icu',
          icu!,
          '--timeout-ms',
          '30000',
          '--out',
          out,
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      clock.stop();
      final lines = '${result.stderr}'.split('\n').map((line) => line.trim());
      expect(result.exitCode, 1, reason: '${result.stderr}');
      expect(
        lines.where(saysNotStarted),
        hasLength(1),
        reason: '${result.stderr}',
      );
      expect(lines.any((line) => line.endsWith(fix)), isTrue);
      expect(File(out).existsSync(), isFalse);
      // It waited out all 30 s before.
      expect(clock.elapsed, lessThan(const Duration(seconds: 10)));
    },
    skip: ready ? false : 'build the runner and example/hello first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

/// [assets] copied into [into] with its kernel's format version made 1:
/// what the engine sees of an app built with another Flutter (#408).
String _otherFlutterBundle(String assets, Directory into) {
  final copy = p.join(into.path, 'flutter_assets');
  for (final entity in Directory(assets).listSync(recursive: true)) {
    final to = p.join(copy, p.relative(entity.path, from: assets));
    if (entity is Directory) {
      Directory(to).createSync(recursive: true);
    }
    if (entity is File) {
      Directory(p.dirname(to)).createSync(recursive: true);
      entity.copySync(to);
    }
  }
  // The header: a magic number, then the format version, big-endian.
  final kernel = File(p.join(copy, 'kernel_blob.bin'));
  final bytes = kernel.readAsBytesSync();
  ByteData.sublistView(bytes).setUint32(4, 1);
  kernel.writeAsBytesSync(bytes);
  return copy;
}

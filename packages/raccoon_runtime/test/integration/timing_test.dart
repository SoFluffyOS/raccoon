// Drives the real runner: the tests that bound a frame rate or a wait. Tagged
// timing: CI runs them after the rest, one file at a time, so nothing beside
// them slows them (#382, #383, #413). Skipped when the runner or its inputs are
// not built; see native/raccoon_runner/tool/render_example.sh. What the files
// share is in test/support/runner_fixture.dart.

@Tags(['timing'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:raccoon/raccoon.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

import '../support/runner_fixture.dart';

// The fixture's helpers, by the names these tests have always used.
const _blue = blue;
final _pictureLine = pictureLine;
const _pixel = pixel;
const _expectExit = expectExit;
const _exitCode = runnerExitCode;
const _pluginEntry = pluginEntry;
const _runHelper = runHelper;

void main() {
  final RunnerFixture(
    :runnerDir,
    :environment,
    :binary,
    :assets,
    :sdk,
    :revision,
    :engineDir,
    :icu,
    :ready,
    :cameraAssets,
    :testVideo,
    :pluginLibrary,
    :flutterFramework,
    :pluginsModalAssets,
    :noPluginAssets,
    :noPluginLateAssets,
  ) = RunnerFixture();
  test(
    'headless, the app renders at 60 Hz with no client, its VM service '
    'answers, and a client that comes later gets the current frame',
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
          headless: true,
        ),
      );
      // Said as it stops, with how many frames it presented.
      final presented = runner.stderr
          .map(RegExp(r'(\d+) frames presented in (\d+) ms').firstMatch)
          .firstWhere((match) => match != null);
      presented.ignore();
      RunnerClient? client;
      try {
        // The VM service, through its WebSocket, with nobody on the socket.
        final http = Uri.parse(
          await runner.vmServiceUri.timeout(const Duration(seconds: 10)),
        );
        final ws = await WebSocket.connect(
          http.replace(scheme: 'ws', path: '${http.path}ws').toString(),
        );
        ws.add(jsonEncode({'jsonrpc': '2.0', 'id': '1', 'method': 'getVM'}));
        final vm =
            jsonDecode(
                  await ws.first.timeout(const Duration(seconds: 10)) as String,
                )
                as Map<String, Object?>;
        await ws.close();
        expect((vm['result'] as Map)['type'], 'VM');

        await Future<void>.delayed(const Duration(seconds: 3));
        final held = await _HeldWatch.start();
        final watch = Stopwatch()..start();
        client = await RunnerClient.connect(endpoint);
        final first = await client.frames.first.timeout(
          const Duration(seconds: 10),
        );
        final late = watch.elapsedMilliseconds;
        final heldMillis = await held.stop();
        printOnFailure(
          'late client $late ms, this process held up for $heldMillis ms '
          'of it; the runner said:\n  ${runner.lastLines.join('\n  ')}',
        );
        expect(first.width, 800);
        client.shutdown();
        await client.close();
        client = null;
        await _expectExit(runner);
        final count = await presented.timeout(const Duration(seconds: 5));
        final frames = int.parse(count!.group(1)!);
        final millis = int.parse(count.group(2)!);
        final firstFrame =
            runner.lastLines
                .map(RegExp(r'first frame (\d+) ms after launch').firstMatch)
                .nonNulls
                .map((match) => int.parse(match.group(1)!))
                .firstOrNull;
        final drawing = millis - (firstFrame ?? 0);
        printOnFailure(
          '$frames frames in $millis ms, the first at $firstFrame ms',
        );
        // Frames go on with nobody there: at 60 Hz on a desktop, at a
        // tenth of it at the least on a slow CI machine (macOS x64 drew
        // 87 in 3.8 s), and never faster than the vsync.
        expect(frames, greaterThan(drawing * 6 ~/ 1000));
        expect(frames, lessThanOrEqualTo(millis * 60 ~/ 1000 + 2));
        // The late client's frame is the one the runner already has, sent
        // in the loop's next turn: it comes within a second's worth of the
        // machine's own frames, 60 of them, 1 s at 60 Hz, about 3 s on the
        // macOS x64 CI machine at 20 fps. Plus however long the machine
        // held this process up meanwhile: that CI machine stalls now and
        // then, and its late client once waited 2048 ms (#382).
        final interval = max(drawing / frames, 1000 / 60);
        expect(late, lessThan(heldMillis + 60 * interval));
        expect(runner.lastLines, contains(startsWith('🦝 headless')));
      } finally {
        if (client != null) {
          client.shutdown();
          await client.close();
          await _exitCode(runner);
        }
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );
  // #368: the tool pings the device as a run starts, seconds before it
  // installs; the ping starts the engine's download so it overlaps the
  // tool's compile, and an install that finds it going waits for it.
  test(
    'a ping starts the engine download, and install waits for it',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_prefetch');
      addTearDown(() => temp.deleteSync(recursive: true));
      final library = p.basename(
        RuntimeStore.engineLibraryOf(RuntimeStore.hostPlatform),
      );
      final zip = ZipEncoder().encodeBytes(
        Archive()..addFile(ArchiveFile.bytes(library, [1, 2, 3])),
      );
      var downloads = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        downloads++;
        // Long enough for the install to find it going.
        await Future<void>.delayed(const Duration(seconds: 2));
        request.response.add(zip);
        await request.response.close();
      });
      addTearDown(server.close);
      final engines = p.join(temp.path, 'engines');
      final environment = {
        'FLUTTER_ROOT': sdk!,
        'XDG_DATA_HOME': p.join(temp.path, 'data'),
        'XDG_RUNTIME_DIR': temp.path,
        'TMPDIR': '${temp.path}/',
        'RACCOON_PLUGINS': 'off',
        'RACCOON_RUNNER': binary!,
        'RACCOON_ENGINE_CACHE': engines,
        'FLUTTER_STORAGE_BASE_URL': 'http://127.0.0.1:${server.port}',
      };

      final watch = Stopwatch()..start();
      final ping = await _runHelper(runnerDir, ['ping'], environment);
      expect(ping.exitCode, 0, reason: '${ping.stderr}');
      // Back at once: nothing of the download holds the tool's pipes.
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (downloads == 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(downloads, 1);
      // Another ping starts no second one.
      expect((await _runHelper(runnerDir, ['ping'], environment)).exitCode, 0);

      final install = await _runHelper(runnerDir, [
        'install',
        assets,
        'app',
      ], environment);
      expect(install.exitCode, 0, reason: '${install.stderr}');
      expect(downloads, 1);
      // The ping's download, waited for: the install downloaded nothing.
      expect('${install.stderr}', isNot(contains('downloaded')));
      final installed =
          RuntimeStore(cacheDirectory: engines).installed(revision!)!;
      expect(File(installed.engineLibrary).readAsBytesSync(), [1, 2, 3]);
      // The ping's download lets go of its lock as it ends, just after.
      final lock = File('${installed.directory}.downloading');
      final gone = DateTime.now().add(const Duration(seconds: 5));
      while (lock.existsSync() && DateTime.now().isBefore(gone)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(lock.existsSync(), isFalse);
    },
    skip: switch ((ready && revision != null, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'the ping starts it on Linux and macOS',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  // #118: a socket path must fit in 104 bytes on macOS. An app whose key
  // doesn't fit runs under a shorter socket name, its key in a .name file.
  // Non-ASCII names count in bytes, and are cut by whole characters, in a
  // UTF-8 locale or in none (an IDE started from the Finder) (#340).
  for (final (label, name, locale) in [
    ('', 'a_flutter_app_${'with_a_very_long_name_' * 4}x', null),
    (
      ' (Vietnamese, UTF-8 locale)',
      'ứng_dụng_${'thời_tiết_của_tôi_' * 4}x',
      Platform.isMacOS ? 'en_US.UTF-8' : 'C.UTF-8',
    ),
    // An emoji is 4 bytes: one of these four offsets has the cut land
    // inside one.
    for (final lead in ['', 'a', 'aa', 'aaa'])
      (' (emoji after "$lead", C locale)', '$lead${'🦝' * 30}', 'C'),
  ]) {
    test(
      'an app whose name is too long for a socket path still runs$label',
      () async {
        final temp = Directory.systemTemp.createTempSync('raccoon_long');
        final helper = p.join(runnerDir, 'tool', 'raccoon-device');
        final environment = {
          if (locale != null) 'LC_ALL': locale,
          'RACCOON_RUNNER': binary!,
          if (sdk != null) 'FLUTTER_ROOT': sdk,
          'XDG_DATA_HOME': p.join(temp.path, 'data'),
          'XDG_RUNTIME_DIR': temp.path,
          'TMPDIR': '${temp.path}/',
        };
        // When each step was done, for a failure's message: three times on
        // CI's x64 Mac no first frame came in 15 s, and nothing said why
        // (#383).
        final clock = Stopwatch()..start();
        final epoch = DateTime.now().millisecondsSinceEpoch;
        final steps = <String>[];
        void done(String step) =>
            steps.add('$step at ${clock.elapsedMilliseconds} ms');
        final install = await Process.run(helper, [
          'install',
          assets,
          name,
        ], environment: environment);
        done('installed');
        expect(install.exitCode, 0, reason: '${install.stderr}');
        final watch = await _HeldWatch.start();
        final run = await Process.start(helper, [
          'run',
          name,
        ], environment: environment);
        done('run started');
        final output = <String>[];
        run.stderr.transform(utf8.decoder).listen(output.add);
        run.stdout.drain<void>().ignore();
        try {
          final discovery = RunnerDiscovery(p.join(temp.path, 'raccoon'));
          final deadline = DateTime.now().add(const Duration(seconds: 30));
          while (discovery.list().isEmpty &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          final found = discovery.list();
          done('listed');
          expect(found, hasLength(1), reason: output.join());
          expect(RunnerDiscovery.appNameOf(found.single), name);
          expect(
            FileStat.statSync(p.join(temp.path, 'raccoon')).mode & 0x1ff,
            0x1c0,
            reason: 'the helper leaves its socket directory rwx------',
          );
          final client = await RunnerClient.connect(found.single);
          done('connected');
          try {
            await client.frames.first.timeout(const Duration(seconds: 15));
            done('first frame');
          } finally {
            client.shutdown();
            await client.close();
          }
        } finally {
          done('given up or done');
          final longest = await watch.stop();
          final said = output.join().trimRight().split('\n');
          printOnFailure(
            '${steps.join(', ')}. This process was held up for $longest ms '
            'at the longest; held up at all (ms at): '
            '${watch.describe(epoch)}. The helper and the runner last '
            'said:\n'
            '${said.skip(max(0, said.length - 30)).join('\n')}',
          );
          run.kill();
          await run.exitCode;
          temp.deleteSync(recursive: true);
        }
      },
      skip: switch ((ready, Platform.isWindows)) {
        (false, _) => 'build the runner and example first',
        (_, true) => 'Windows keeps sockets under %TEMP%, with its own limit',
        _ => false,
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
  test(
    'the runner answers the camera plugin from a test pattern',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: cameraAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final lines = <String>[];
      final done = Completer<void>();
      String? heldPath;
      var framesSeen = 0;
      var framesAtIdle = 0;
      var framesAfterIdle = 0;
      var framesAtShown = 0;
      var framesAfterShown = 0;
      runner.stdout.listen((line) {
        final at = line.indexOf('CAMERA:');
        if (at < 0) return;
        final said = line.substring(at + 'CAMERA:'.length);
        if (said == 'idle') framesAtIdle = framesSeen;
        if (said == 'idle end') framesAfterIdle = framesSeen;
        if (said == 'shown') framesAtShown = framesSeen;
        if (said == 'shown end') framesAfterShown = framesSeen;
        lines.add(said);
        if ((said == 'done' || said.startsWith('error')) && !done.isCompleted) {
          done.complete();
        }
      });
      final client = await RunnerClient.connect(endpoint);
      final forwarded = <String>[];
      client.registerChannel('plugins.flutter.io/camera', (data) async {
        forwarded.add('plugins.flutter.io/camera');
        return null;
      });
      // The preview fills the view while the first camera streams: the test
      // pattern's first bar is white, its last blue.
      var previewed = false;
      final frames = client.frames.listen((frame) {
        framesSeen++;
        final y = frame.height ~/ 4;
        if (_pixel(frame, frame.width ~/ 14, y) == (r: 255, g: 255, b: 255) &&
            _pixel(frame, frame.width * 13 ~/ 14, y) == (r: 0, g: 0, b: 255)) {
          previewed = true;
        }
      });
      try {
        await done.future.timeout(const Duration(seconds: 30));
        await frames.cancel();
        if (runner.renderer == 'gl' || runner.renderer == 'metal') {
          expect(previewed, isTrue, reason: 'no frame showed the preview');
          // #114: two seconds of a camera nobody shows are a few frames,
          // not sixty.
          final idle = framesAfterIdle - framesAtIdle;
          expect(idle, lessThan(20));
          // Shown again, it runs at its frame rate: two seconds are about
          // 60 frames, the probe's about 8. Measured against the same
          // machine's idle two seconds, twice as many and at least 10: a
          // loaded CI runner drew 12 where 20 was asked for.
          expect(
            framesAfterShown - framesAtShown,
            greaterThan(idle * 2 < 10 ? 10 : idle * 2),
          );
        }
        expect(lines, contains('cameras back,front'));
        expect(lines, contains('initialized 352x288'));
        final picture = _pictureLine.firstMatch(
          lines.firstWhere((l) => l.startsWith('picture')),
        );
        expect(picture?[1], 'bars ok');
        final file = File(picture?[4] ?? '');
        expect(file.readAsBytesSync().take(2), [0xFF, 0xD8]);
        file.deleteSync();
        // Video range: white is 235, blue 41.
        final yuv = lines.firstWhere((l) => l.startsWith('stream yuv420'));
        expect(yuv, contains('planes=3 352x288 y=235/41'));
        final fps = double.parse(yuv.split('fps=').last);
        expect(fps, inInclusiveRange(20, 40));
        expect(
          lines,
          contains(
            startsWith('stream bgra8888 planes=1 raw=1111970369 bars ok'),
          ),
        );
        expect(
          lines,
          contains(startsWith('stream jpeg planes=1 raw=256 bars ok')),
        );
        // 600 ms recorded, 400 paused, 400 more: a second of video on
        // Windows, the pattern in it; refused elsewhere.
        final video = lines.firstWhere((l) => l.startsWith('video '));
        if (Platform.isWindows) {
          final path = video.substring('video '.length);
          final probe = await Process.run(testVideo, ['--probe', path]);
          final held = RegExp(
            r'frames=(\d+) size=(\S+) duration_ms=(\d+) left=(\S+) right=(\S+)',
          ).firstMatch('${probe.stdout}');
          expect(held, isNotNull, reason: '${probe.stdout}${probe.stderr}');
          // About 30 frames a second, for no longer than the app says it
          // recorded (#329): a pause that doesn't pause adds its 400 ms.
          final recordedMs = int.parse(
            lines
                .firstWhere((l) => l.startsWith('video_ms '))
                .substring('video_ms '.length),
          );
          expect(
            int.parse(held?[1] ?? '0'),
            inInclusiveRange(25, recordedMs * 30 ~/ 1000 + 6),
            reason: 'recorded for at most $recordedMs ms',
          );
          expect(held?[2], '352x288');
          // Its length too: the 250 ms of room is less than the 400 a pause
          // that doesn't pause adds.
          expect(
            int.parse(held?[3] ?? '0'),
            inInclusiveRange(850, recordedMs + 250),
            reason: 'recorded for at most $recordedMs ms',
          );
          final left = (held?[4] ?? '').split(',').map(int.parse);
          final right = (held?[5] ?? '').split(',').map(int.parse).toList();
          expect(left.every((c) => c > 230), isTrue, reason: 'left $left');
          expect(
            right[0] < 30 && right[1] < 30 && right[2] > 220,
            isTrue,
            reason: 'right $right',
          );
          File(path).deleteSync();
          // Stopped as soon as it started, before the loop's next turn: a
          // video of one frame, not a failure and an empty file.
          final instant = lines
              .firstWhere((l) => l.startsWith('video_instant '))
              .substring('video_instant '.length);
          final one = await Process.run(testVideo, ['--probe', instant]);
          expect(
            '${one.stdout}',
            matches(RegExp(r'frames=[1-9]')),
            reason: '$instant: ${one.stdout}${one.stderr}',
          );
          File(instant).deleteSync();
          // The recording never stopped is the next file by the same name.
          final name = RegExp(
            r'^(.*raccoon_camera_\d+_)(\d+)\.mp4$',
          ).firstMatch(instant);
          heldPath = '${name?[1]}${int.parse(name?[2] ?? '0') + 1}.mp4';
          expect(lines, contains('video_held'));
        } else {
          expect(video, 'video refused videoRecordingFailed');
        }
        expect(lines.last, 'done');
        expect(forwarded, isEmpty);
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
      // The runner went with a recording under way: the file is a video
      // all the same, not one without its index that nothing plays.
      if (heldPath case final held?) {
        final probe = await Process.run(testVideo, ['--probe', held]);
        expect(
          '${probe.stdout}',
          matches(RegExp(r'frames=[1-9]')),
          reason: '$held: ${probe.stdout}${probe.stderr}',
        );
        File(held).deleteSync();
      }
    },
    skip:
        ready && Directory(cameraAssets).existsSync()
            ? false
            : 'build the runner and example/camera first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'on Windows frames keep their pace with a temp path too long for a socket',
    () async {
      // #126: the event loop's wake is a pair of sockets named in the temp
      // directory; a path past a socket name's 108 bytes made none, and
      // the loop woke once a second. The loopback stands in.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final long = Directory(p.join(temp.path, 'x' * 60, 'y' * 60))
        ..createSync(recursive: true);
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
        startProcess:
            (executable, arguments) => Process.start(
              executable,
              arguments,
              environment: {'TEMP': long.path, 'TMP': long.path},
            ),
      );
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.frames.first.timeout(const Duration(seconds: 15));
        final watch = Stopwatch()..start();
        final frames = await client.frames
            .takeWhile((_) => watch.elapsed < const Duration(seconds: 2))
            .length
            .timeout(const Duration(seconds: 10));
        expect(frames, greaterThan(20));
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, false) => 'the wake socket pair is Windows\' own',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'a client behind the frames still gets them through the shared buffers',
    () async {
      // Busy for two frames' time with each, the client has both buffers
      // unread when the next frame comes. That frame went inline, its
      // pixels through the socket to a client already behind; it waits for
      // a buffer now.
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
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.frames
            .firstWhere((_) => client.sharedFrames > 0)
            .timeout(const Duration(seconds: 15));
        final sharedBefore = client.sharedFrames;
        var frames = 0;
        final busy = client.frames.listen((_) {
          frames++;
          final spent = Stopwatch()..start();
          while (spent.elapsedMilliseconds < 35) {}
        });
        await Future<void>.delayed(const Duration(seconds: 3));
        await busy.cancel();
        expect(frames, greaterThan(20));
        // The count is taken as a frame is read and the listener hears of
        // it later, so a frame at either end may fall on the other side;
        // and a frame that waited out the runner's inline hold (100 ms) for
        // a buffer goes inline by design, which a slow host sees now and
        // then. Nine in ten through the buffers: before, most went inline.
        expect(
          client.sharedFrames - sharedBefore,
          greaterThanOrEqualTo(frames * 9 ~/ 10 - 2),
        );
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'shared buffers are Unix sockets',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'frames of a pane being dragged larger keep to the shared buffers',
    () async {
      // The buffers were sized to each frame exactly: every frame of a
      // growing pane missed them and went inline, ten megabytes through the
      // socket each, while they were made anew. They have room now.
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
      final client = await RunnerClient.connect(endpoint);
      try {
        var frames = 0;
        final counting = client.frames.listen((_) => frames++);
        await client.frames
            .firstWhere((_) => client.sharedFrames > 0)
            .timeout(const Duration(seconds: 15));
        final framesBefore = frames;
        final sharedBefore = client.sharedFrames;
        for (var i = 0; i < 120; i++) {
          client.resize(1000 + i * 4, 700 + i * 3, 2.0);
          await Future<void>.delayed(const Duration(milliseconds: 16));
        }
        await counting.cancel();
        final dragged = frames - framesBefore;
        final shared = client.sharedFrames - sharedBefore;
        printOnFailure('$shared of $dragged frames shared');
        // Enough to judge by; CI's x64 Mac draws 17 in the drag.
        expect(dragged, greaterThan(5));
        expect(shared / dragged, greaterThan(0.7));
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'shared buffers are Unix sockets',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'a client nobody watches reads its frames only when asked',
    () async {
      // With no listener (a view gone with its tab), shared frames stay
      // unread in their buffer; latestFrame reads the latest when asked,
      // and a listener that comes later gets frames with pixels.
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
      final client = await RunnerClient.connect(endpoint);
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (client.sharedFrames < 20 && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        // Still turning: the runner gets its buffers back unread.
        expect(client.sharedFrames, greaterThanOrEqualTo(20));
        final latest = client.latestFrame;
        expect(latest?.inSharedBuffer, isFalse);
        expect(latest?.pixels.length, latest!.rowBytes * latest.height);
        expect(latest.pixels.any((byte) => byte != 0), isTrue);
        final watched = await client.frames
            .skip(1)
            .first
            .timeout(const Duration(seconds: 5));
        expect(watched.pixels.any((byte) => byte != 0), isTrue);
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'shared buffers are Unix sockets',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
  // #144: writes to a client that read nothing blocked the loop, the app's
  // platform thread, for up to 5 s at a time. They queue now: the runner
  // goes on, answering a newcomer at once, and the client keeps its place
  // however long it pauses, as in a debugger.
  test(
    'a client that reads nothing holds up neither the runner nor its place',
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
      final paused = await Socket.connect(
        InternetAddress(endpoint.path, type: InternetAddressType.unix),
        0,
      );
      try {
        // Says hello, then reads nothing: its first frame, megabytes, waits
        // in the runner's queue behind a full socket.
        paused.add(
          MessageFraming.frame(
            ClientMessage(
              hello: ClientHello(protocolVersion: 1, pid: 1),
            ).writeToBuffer(),
          ),
        );
        await paused.flush();
        await Future<void>.delayed(const Duration(seconds: 1));

        // The loop is free: a newcomer is told at once that the runner is
        // taken, not after a write to the paused client gave up.
        final started = DateTime.now();
        final newcomer = await RunnerClient.connect(endpoint);
        await expectLater(
          newcomer.hello.timeout(const Duration(seconds: 2)),
          throwsA(isA<RunnerBusy>()),
        );
        expect(
          DateTime.now().difference(started),
          lessThan(const Duration(seconds: 2)),
        );
        await newcomer.close();

        // Paused past what a blocked write used to wait, it still has its
        // place, and its frame is there once it reads.
        await Future<void>.delayed(const Duration(seconds: 6));
        final received = <int>[];
        final ended = Completer<void>();
        paused.listen(received.addAll, onDone: () => ended.complete());
        final unframer = MessageUnframer();
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        var sawFrame = false;
        while (!sawFrame && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          for (final payload in unframer.add(List.of(received))) {
            if (RunnerMessage.fromBuffer(payload).hasFrame()) sawFrame = true;
          }
          received.clear();
        }
        expect(sawFrame, isTrue);
        expect(ended.isCompleted, isFalse);
        paused.add(
          MessageFraming.frame(
            ClientMessage(shutdown: Shutdown()).writeToBuffer(),
          ),
        );
        await paused.flush();
        expect(await _exitCode(runner), 0);
      } finally {
        paused.destroy();
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'a raw socket stands in for a client',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'frames keep coming while a plugin\'s modal dialog runs its own loop',
    () async {
      // A modal dialog's loop holds the runner's until it closes: a message
      // loop on Windows, the run loop in its modal panel mode on macOS, a
      // nested GLib loop on Linux. The runner takes its turns from a timer
      // meanwhile.
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
          assets: pluginsModalAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          plugins: manifest.path,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      var modal = false;
      var inner = false;
      var during = 0;
      var duringInner = 0;
      final done = Completer<String>();
      runner.stdout.listen((line) {
        if (line.contains('MODAL:start')) modal = true;
        if (line.contains('MODAL:inner done')) {
          inner = false;
        } else if (line.contains('MODAL:inner')) {
          inner = true;
        }
        if (line.contains('MODAL:done') || line.contains('MODAL:error')) {
          modal = false;
          if (!done.isCompleted) done.complete(line);
        }
      });
      final frames = client.frames.listen((_) {
        if (modal) during++;
        if (inner) duringInner++;
      });
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        expect(
          await done.future.timeout(const Duration(seconds: 20)),
          contains('MODAL:done'),
        );
        // Two seconds at 60 Hz are 120 frames; a held loop sends none, so
        // 4 tells them apart on a loaded CI runner too (one drew 27, a
        // macos-x64 one 10).
        expect(during, greaterThan(4));
        // A dialog opened from a turn the first one's loop took has a loop
        // of its own, which takes turns too: a second of it is 60 frames.
        // macOS still holds the runner there: 1 frame (#337).
        if (!Platform.isMacOS) expect(duringInner, greaterThan(2));
      } finally {
        await frames.cancel();
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready &&
                File(pluginLibrary).existsSync() &&
                Directory(pluginsModalAssets).existsSync()
            ? false
            : 'build the runner with plugins and example/plugins_modal first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'a stop while a plugin\'s dialog is open ends the runner',
    () async {
      // The client's Shutdown, a tool gone or a later run taking the socket
      // all come in a turn the dialog's loop takes; the runner's own loop,
      // which would act on them, waits under the dialog. The dialog's loop
      // is asked to end instead: by WM_QUIT on Windows, g_main_loop_quit
      // on Linux.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final manifest = File(p.join(temp.path, 'plugins.json'))
        ..writeAsStringSync(
          jsonEncode({
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
          assets: pluginsModalAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          plugins: manifest.path,
        ),
      );
      final started = Completer<void>();
      runner.stdout.listen((line) {
        if (line.contains('MODAL:start') && !started.isCompleted) {
          started.complete();
        }
      });
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        await started.future.timeout(const Duration(seconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final stopping = Stopwatch()..start();
        client.shutdown();
        // The dialog would close by itself 2.7 s from here.
        expect(await _exitCode(runner), 0);
        expect(stopping.elapsedMilliseconds, lessThan(1500));
      } finally {
        await client.close();
        runner.kill();
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        Platform.isMacOS
            ? 'a stop waits for the dialog on macOS still (#337)'
            : ready &&
                File(pluginLibrary).existsSync() &&
                Directory(pluginsModalAssets).existsSync()
            ? false
            : 'build the runner with plugins and example/plugins_modal first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
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
            (line) => line.startsWith('🦝 nothing answered $pigeonChannel ('),
          ),
          isTrue,
        );
        expect(client.latestFrame, isNull);
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
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
        await _expectExit(runner);
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

/// How long this process went without running, at the longest, while a
/// test waits: an isolate of its own ticks every few milliseconds, so the
/// test's own work doesn't count, only a machine that held the whole
/// process up.
class _HeldWatch {
  _HeldWatch._(this._isolate, this._replies, this._stop);

  static const _tick = Duration(milliseconds: 2);

  /// A hold this long or longer, past the tick, is kept in [holds].
  static const _noted = 20;

  final Isolate _isolate;
  final StreamIterator<Object?> _replies;
  final SendPort _stop;
  Future<int>? _stopped;

  /// The holds of [_noted] ms or more, once stopped: when each started, in
  /// milliseconds since the epoch, and how long it was.
  var holds = const <(int, int)>[];

  static Future<_HeldWatch> start() async {
    final port = ReceivePort();
    final replies = StreamIterator<Object?>(port);
    final isolate = await Isolate.spawn(_watch, port.sendPort);
    await replies.moveNext();
    return _HeldWatch._(isolate, replies, replies.current! as SendPort);
  }

  /// The longest time the watch went without a tick, past its own tick.
  /// Again, the same answer.
  Future<int> stop() => _stopped ??= _stopOnce();

  Future<int> _stopOnce() async {
    _stop.send(null);
    await _replies.moveNext();
    final [longest as int, ...noted] = _replies.current! as List<Object?>;
    await _replies.cancel();
    _isolate.kill();
    holds = [
      for (var i = 0; i < noted.length; i += 2)
        (noted[i]! as int, noted[i + 1]! as int),
    ];
    return max(0, longest - _tick.inMilliseconds);
  }

  /// [holds] for a failure's message, from [since] (since the epoch).
  String describe(int since) =>
      holds.isEmpty
          ? 'none of $_noted ms or more'
          : holds
              .map((hold) => '${hold.$2} ms at ${hold.$1 - since}')
              .join(', ');

  static void _watch(SendPort out) {
    final control = ReceivePort();
    out.send(control.sendPort);
    final clock = Stopwatch()..start();
    final epoch = DateTime.now().millisecondsSinceEpoch;
    var last = 0;
    var longest = 0;
    final noted = <int>[];
    void tick() {
      final now = clock.elapsedMilliseconds;
      final gap = now - last;
      longest = max(longest, gap);
      final held = gap - _tick.inMilliseconds;
      if (held >= _noted) noted.addAll([epoch + last, held]);
      last = now;
    }

    final ticks = Timer.periodic(_tick, (_) => tick());
    control.first.then((_) {
      ticks.cancel();
      tick();
      out.send([longest, ...noted]);
      control.close();
    });
  }
}

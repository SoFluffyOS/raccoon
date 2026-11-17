// Drives the real runner: one run, several views: each its own size, taps and
// GPU buffers, from the views entry. Skipped when the runner or its inputs are
// not built; see native/raccoon_runner/tool/render_example.sh. What the files
// share is in test/support/runner_fixture.dart.

import 'dart:async';
import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:path/path.dart' as p;
import 'package:raccoon/raccoon.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

import '../support/runner_fixture.dart';

// The fixture's helpers, by the names these tests have always used.
const _blue = blue;
const _red = red;
const _green = green;
const _white = white;
const _orange = orange;
const _pixel = pixel;
const _expectExit = expectExit;

// What the views entry shows in a view it refused.
const _noticeGrey = (r: 0x20, g: 0x21, b: 0x24);

void main() {
  final RunnerFixture(
    :runnerDir,
    :binary,
    :assets,
    :sdk,
    :engineDir,
    :icu,
    :ready,
    :viewsAssets,
  ) = RunnerFixture();
  test(
    'a runner whose views socket cannot listen says it takes no views',
    () async {
      // #251: a folder where the views socket goes, so it cannot bind.
      final temp = Directory.systemTemp.createTempSync('raccoon_views');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      Directory(endpoint.views.path).createSync();
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: viewsAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          width: 390,
          height: 300,
          views: true,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        expect(client.takesViews, isFalse);
        // The app still draws for its first client.
        final frame = await client.frames.first.timeout(
          const Duration(seconds: 15),
        );
        expect((frame.width, frame.height), (390, 300));
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(viewsAssets).existsSync()
            ? false
            : 'build the runner and example/views first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'one run shows the app in a view per client, each its size and its taps',
    () async {
      // #182: example/views draws its root in every view, coloured by the
      // view's id (0 blue, 1 green, 2 orange), a box in the middle that a
      // tap turns from red to white.
      final temp = Directory.systemTemp.createTempSync('raccoon_views');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: viewsAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          width: 390,
          height: 300,
          views: true,
        ),
      );
      final first = await RunnerClient.connect(endpoint);
      final others = <RunnerClient>[];
      try {
        await first.hello.timeout(const Duration(seconds: 10));
        expect(first.takesViews, isTrue);
        expect(first.viewId, 0);
        final own = await first.frames.first.timeout(
          const Duration(seconds: 15),
        );
        expect((own.width, own.height), (390, 300));
        expect(_pixel(own, 5, 5), _blue);

        final second = await RunnerClient.connect(endpoint.views);
        others.add(second);
        await second.hello.timeout(const Duration(seconds: 10));
        expect(second.viewId, 1);
        second.resize(300, 200, 2);
        final frame = await second.frames
            .firstWhere((f) => f.width == 300)
            .timeout(const Duration(seconds: 15));
        expect(frame.height, 200);
        expect(_pixel(frame, 5, 5), _green);
        expect(_pixel(frame, 150, 100), _red);

        for (final (phase, buttons) in [
          (PointerPhase.POINTER_PHASE_DOWN, 1),
          (PointerPhase.POINTER_PHASE_UP, 0),
        ]) {
          second.sendPointer(
            PointerEvent(
              phase: phase,
              x: 150,
              y: 100,
              buttons: Int64(buttons),
              device: PointerDevice.POINTER_DEVICE_MOUSE,
              pointerId: 1,
            ),
          );
        }
        await second.frames
            .firstWhere((f) => _pixel(f, 150, 100) == _white)
            .timeout(const Duration(seconds: 10));
        // Each view has its own instance: the first's box stays red.
        expect(_pixel(first.latestFrame!, 195, 150), _red);

        // A view goes with its client; the next client has a new one.
        await second.close();
        final third = await RunnerClient.connect(endpoint.views);
        others.add(third);
        await third.hello.timeout(const Duration(seconds: 10));
        expect(third.viewId, 2);
        third.resize(200, 100, 1);
        final last = await third.frames
            .firstWhere((f) => f.width == 200)
            .timeout(const Duration(seconds: 15));
        expect(_pixel(last, 5, 5), _orange);
      } finally {
        for (final other in others) {
          await other.close();
        }
        first.shutdown();
        await first.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(viewsAssets).existsSync()
            ? false
            : 'build the runner and example/views first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'an app that only calls runApp draws in every view from the views entry',
    () async {
      // example/hello as it is, built through the generated entry point.
      final temp = Directory.systemTemp.createTempSync('raccoon_entry');
      final app = Directory(p.join(temp.path, 'hello'))..createSync();
      final hello = p.join(runnerDir, 'example', 'hello');
      for (final file in [
        'pubspec.yaml',
        'pubspec.lock',
        p.join('lib', 'main.dart'),
        p.join('.dart_tool', 'package_config.json'),
      ]) {
        final copy = File(p.join(app.path, file))
          ..parent.createSync(recursive: true);
        File(p.join(hello, file)).copySync(copy.path);
      }
      try {
        final entry = ViewsEntrypoint.write(app.path);
        expect(entry, p.join(app.path, ViewsEntrypoint.path));
        final target = switch (Platform.operatingSystem) {
          'macos' => 'darwin',
          'windows' => 'windows-x64',
          _ when Platform.version.contains('arm64') => 'linux-arm64',
          _ => 'linux-x64',
        };
        final build = await Process.run(
          p.join(sdk!, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter'),
          ['build', 'bundle', '-t', entry!, '--target-platform=$target'],
          workingDirectory: app.path,
          runInShell: Platform.isWindows,
        );
        expect(build.exitCode, 0, reason: '${build.stdout}${build.stderr}');
        final out = p.join(temp.path, 'frame.ppm');
        final render = await Process.run(binary!, [
          'render',
          '--engine-dir',
          engineDir!,
          '--assets',
          p.join(app.path, 'build', 'flutter_assets'),
          '--icu',
          icu!,
          '--view',
          '600x400@1',
          '--out',
          out,
        ]);
        expect(render.exitCode, 0, reason: '${render.stderr}');
        for (final (file, width) in [
          (out, 800),
          (p.join(temp.path, 'frame.view1.ppm'), 600),
        ]) {
          final bytes = File(file).readAsBytesSync();
          // P6, width, height, 255, then RGB from the first pixel.
          final header = String.fromCharCodes(
            bytes.take(32),
          ).split(RegExp(r'\s+'));
          expect(int.parse(header[1]), width);
          final start =
              '${header[0]}\n${header[1]} ${header[2]}\n${header[3]}\n'.length;
          expect((
            r: bytes[start],
            g: bytes[start + 1],
            b: bytes[start + 2],
          ), _blue);
        }
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready && sdk != null ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'the generated entry shows the app with the device\'s safe area and '
    'platform',
    () async {
      // #194: example/hello's packages, a main that prints what it is laid
      // out with each build.
      final temp = Directory.systemTemp.createTempSync('raccoon_device');
      final app = Directory(p.join(temp.path, 'hello'))..createSync();
      final hello = p.join(runnerDir, 'example', 'hello');
      for (final file in [
        'pubspec.yaml',
        'pubspec.lock',
        p.join('.dart_tool', 'package_config.json'),
      ]) {
        final copy = File(p.join(app.path, file))
          ..parent.createSync(recursive: true);
        File(p.join(hello, file)).copySync(copy.path);
      }
      File(p.join(app.path, 'lib', 'main.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

void main() => runApp(const Report());

class Report extends StatelessWidget {
  const Report({super.key});

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final viewPadding = MediaQuery.viewPaddingOf(context);
    print('DEVICE:\${defaultTargetPlatform.name};\${padding.top};'
        '\${padding.bottom};\${viewPadding.bottom}');
    return const SizedBox();
  }
}
''');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      RunnerProcess? runner;
      RunnerClient? client;
      try {
        final entry = RaccoonEntrypoint.write(app.path);
        expect(entry, p.join(app.path, RaccoonEntrypoint.path));
        final build = await Process.run(
          p.join(sdk!, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter'),
          ['build', 'bundle', '-t', entry!],
          workingDirectory: app.path,
          runInShell: Platform.isWindows,
        );
        expect(build.exitCode, 0, reason: '${build.stdout}${build.stderr}');
        runner = await RunnerProcess.start(
          RunnerLaunch(
            runnerBinary: binary!,
            engineDir: engineDir!,
            assets: p.join(app.path, 'build', 'flutter_assets'),
            icuData: icu!,
            endpoint: endpoint,
          ),
        );
        final output = <String>[];
        runner.stdout.listen(output.add);
        client = await RunnerClient.connect(endpoint);
        final device =
            DeviceChannel()
              ..fallback = const DeviceProfile(
                padding: (top: 47, right: 0, bottom: 34, left: 0),
                platform: 'iOS',
              );
        device.attach(client);
        await client.hello.timeout(const Duration(seconds: 10));
        Future<void> laidOut(String line) async {
          final deadline = DateTime.now().add(const Duration(seconds: 15));
          while (!output.contains(line) && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(output, contains(line));
        }

        client.resize(1170, 2532, 3);
        await laidOut('DEVICE:iOS;47.0;34.0;34.0');
        // A keyboard 300 high covers the home indicator: no padding left
        // below, the view's padding the same.
        client.setViewInsets(bottom: 900);
        await laidOut('DEVICE:iOS;47.0;0.0;34.0');
      } finally {
        client?.shutdown();
        await client?.close();
        if (runner != null) await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready && sdk != null ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'a second view of an app whose root holds a global key is refused, and '
    'the first view goes on',
    () async {
      // The views entry around a main whose root widget's key is a global
      // one, as an app-wide navigator key is.
      final temp = Directory.systemTemp.createTempSync('raccoon_refused');
      final app = Directory(p.join(temp.path, 'hello'))..createSync();
      final hello = p.join(runnerDir, 'example', 'hello');
      for (final file in [
        'pubspec.yaml',
        'pubspec.lock',
        p.join('.dart_tool', 'package_config.json'),
      ]) {
        final copy = File(p.join(app.path, file))
          ..parent.createSync(recursive: true);
        File(p.join(hello, file)).copySync(copy.path);
      }
      File(p.join(app.path, 'lib', 'main.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
import 'package:flutter/widgets.dart';

final rootKey = GlobalKey();

void main() => runApp(
  ColoredBox(key: rootKey, color: const Color(0xFF1E88E5)),
);
''');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      RunnerProcess? runner;
      RunnerClient? first;
      final views = <RunnerClient>[];
      try {
        final entry = ViewsEntrypoint.write(app.path);
        final build = await Process.run(
          p.join(sdk!, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter'),
          ['build', 'bundle', '-t', entry!],
          workingDirectory: app.path,
          runInShell: Platform.isWindows,
        );
        expect(build.exitCode, 0, reason: '${build.stdout}${build.stderr}');
        runner = await RunnerProcess.start(
          RunnerLaunch(
            runnerBinary: binary!,
            engineDir: engineDir!,
            assets: p.join(app.path, 'build', 'flutter_assets'),
            icuData: icu!,
            endpoint: endpoint,
            width: 300,
            height: 200,
            views: true,
          ),
        );
        final output = <String>[];
        runner.stdout.listen(output.add);
        final client = first = await RunnerClient.connect(endpoint);
        final refusals = StreamController<RefusedViews>();
        client.registerChannel(ViewsEntrypoint.channel, (data) async {
          if (RefusedViews.parse(data) case final refused?) {
            refusals.add(refused);
          }
          return null;
        });
        final refused = StreamIterator(refusals.stream);
        await client.hello.timeout(const Duration(seconds: 10));
        final own = await client.frames.first.timeout(
          const Duration(seconds: 15),
        );
        expect(_pixel(own, 150, 100), _blue);

        final second = await RunnerClient.connect(endpoint.views);
        views.add(second);
        await second.hello.timeout(const Duration(seconds: 10));
        second.resize(240, 160, 1);
        expect(
          await refused.moveNext().timeout(const Duration(seconds: 15)),
          isTrue,
        );
        expect(refused.current.views, [second.viewId]);
        expect(refused.current.reason, 'globalKey');
        // The view shows the notice, not the app.
        final notice = await second.frames
            .firstWhere((f) => f.width == 240 && _pixel(f, 5, 5) == _noticeGrey)
            .timeout(const Duration(seconds: 15));
        expect(_pixel(notice, 5, 5), _noticeGrey);
        expect(
          output.any((line) => line.contains("can't show in more than one")),
          isTrue,
          reason: output.join('\n'),
        );

        // Back to one view: the first, which kept its key, draws on.
        await second.close();
        client.resize(320, 200, 1);
        final after = await client.frames
            .firstWhere((f) => f.width == 320)
            .timeout(const Duration(seconds: 15));
        expect(_pixel(after, 160, 100), _blue);

        // A view asked for again is refused again.
        final third = await RunnerClient.connect(endpoint.views);
        views.add(third);
        await third.hello.timeout(const Duration(seconds: 10));
        third.resize(200, 100, 1);
        expect(
          await refused.moveNext().timeout(const Duration(seconds: 15)),
          isTrue,
        );
        expect(refused.current.views, [third.viewId]);
        await refused.cancel();
      } finally {
        for (final view in views) {
          await view.close();
        }
        first?.shutdown();
        await first?.close();
        if (runner != null) await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready && sdk != null ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

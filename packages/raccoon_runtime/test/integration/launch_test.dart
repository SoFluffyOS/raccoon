// Drives the real runner: the app starts, draws its first frame, renders
// headless and on each renderer, and resizes. Skipped when the runner or its
// inputs are not built; see native/raccoon_runner/tool/render_example.sh. What
// the files share is in test/support/runner_fixture.dart.

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
const _pixel = pixel;
const _expectExit = expectExit;

void main() {
  final RunnerFixture(
    :environment,
    :binary,
    :assets,
    :engineDir,
    :icu,
    :ready,
  ) = RunnerFixture();
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
        await _expectExit(runner);
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
    'a named renderer is that one or none, and an unknown name is auto',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_renderer');
      addTearDown(() => temp.deleteSync(recursive: true));
      Future<ProcessResult> render(String renderer) => Process.run(binary!, [
        'render',
        '--engine-dir',
        engineDir!,
        '--assets',
        assets,
        '--icu',
        icu!,
        '--renderer',
        renderer,
        '--out',
        p.join(temp.path, '$renderer.ppm'),
      ]);

      final unknown = await render('bogus');
      expect(unknown.exitCode, 0, reason: '${unknown.stderr}');
      expect('${unknown.stderr}', contains('no renderer "bogus"'));
      expect(File(p.join(temp.path, 'bogus.ppm')).existsSync(), isTrue);

      // One this host never builds: it used to fall through to the next
      // GPU renderer (Metal for vulkan on macOS) without a word.
      final absent = Platform.isMacOS ? 'vulkan' : 'metal';
      final insisted = await render(absent);
      expect(insisted.exitCode, isNot(0));
      expect(
        '${insisted.stderr}',
        contains('built without the $absent renderer'),
      );
    },
    skip: ready ? false : 'build the runner and example first',
  );
  // #379: Impeller has no software backend; the engine aborts on the
  // first text it draws there. Asked for, it is GL's only.
  test(
    'Impeller only when asked, and never on the software renderer',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_impeller');
      addTearDown(() => temp.deleteSync(recursive: true));
      Future<(ProcessResult, String)> render(
        String renderer,
        Map<String, String> environment,
      ) async {
        final out = p.join(temp.path, '$renderer.ppm');
        final result = await Process.run(binary!, [
          'render',
          '--engine-dir',
          engineDir!,
          '--assets',
          assets,
          '--icu',
          icu!,
          '--renderer',
          renderer,
          '--out',
          out,
        ], environment: environment);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(File(out).existsSync(), isTrue);
        // Without the emoji, and its line end trimmed: Windows' console
        // encoding and \r\n.
        final line = '${result.stdout}\n${result.stderr}'
            .split('\n')
            .map((line) => line.trimRight())
            .firstWhere(
              (line) =>
                  line.contains('renderer ') &&
                  (line.endsWith(', Skia') || line.endsWith(', Impeller')),
              orElse: () => '',
            );
        return (result, line);
      }

      final (_, usual) = await render('auto', {});
      expect(usual, endsWith(', Skia'));

      final (software, softwareLine) = await render('software', {
        'RACCOON_IMPELLER': '1',
        'RACCOON_FLUTTER_GPU': '1',
      });
      expect(
        '${software.stderr}',
        contains(
          'Impeller asked for, but the software renderer draws with Skia',
        ),
      );
      expect(softwareLine, endsWith('renderer software, Skia'));

      if (!usual.contains('renderer gl ')) {
        printOnFailure('no GL here: $usual');
        return;
      }
      final (_, impeller) = await render('auto', {'RACCOON_IMPELLER': '1'});
      expect(impeller, contains('renderer gl '));
      expect(impeller, endsWith(', Impeller'));
    },
    skip: ready ? false : 'build the runner and example first',
  );
  // #123: the GL renderer took the first EGL display there was. A device
  // whose eglInitialize failed left the runner on the software renderer
  // with a working EGL device beside it, and Mesa's surfaceless platform,
  // tried first, can be software GL where the GPU's own device is not.
  test(
    'on Linux the GL renderer goes on to the next EGL device when one fails to start',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_egl');
      addTearDown(() => temp.deleteSync(recursive: true));
      Future<String> renderer(Map<String, String> environment) async {
        final result = await Process.run(binary!, [
          'render',
          '--engine-dir',
          engineDir!,
          '--assets',
          assets,
          '--icu',
          icu!,
          '--renderer',
          'auto',
          '--out',
          p.join(temp.path, 'frame.ppm'),
        ], environment: environment);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        return '${result.stdout}\n${result.stderr}'
            .split('\n')
            .firstWhere(
              (line) => line.contains('🦝 renderer '),
              orElse: () => '',
            );
      }

      final usual = await renderer({});
      if (!usual.contains('renderer gl ')) {
        printOnFailure('no GL here: $usual');
        return;
      }
      // EGL devices only: the GPU's render node where GL is the GPU's,
      // else software GL's device.
      final devices = await renderer({'RACCOON_GL_DEVICE': 'device'});
      expect(devices, contains('renderer gl '));
      expect(devices, isNot(contains('EGL surfaceless')));
      if (!usual.contains('llvmpipe')) {
        expect(devices, contains('EGL /dev/dri/render'));
      }
      // No driver loads for the GPU: its device fails eglInitialize, and the
      // software device beside it draws.
      final failing = await renderer({
        'RACCOON_GL_DEVICE': 'device',
        'MESA_LOADER_DRIVER_OVERRIDE': 'raccoon_no_such_driver',
      });
      expect(failing, contains('renderer gl '));
      expect(failing, isNot(contains('EGL surfaceless')));
      // A render node that isn't there leaves no EGL display.
      final missing = await renderer({
        'RACCOON_GL_DEVICE': '/dev/dri/renderD255',
      });
      expect(missing, contains('renderer software (no GL'));
    },
    skip:
        !Platform.isLinux
            ? 'EGL is Linux'
            : ready
            ? false
            : 'build the runner and example first',
  );
  test(
    'a pixel ratio that is no number, or none above 0, renders at 1',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_dpr');
      addTearDown(() => temp.deleteSync(recursive: true));
      for (final ratio in ['0', '-2', 'nan']) {
        final out = p.join(temp.path, 'frame_$ratio.ppm');
        final render = await Process.run(binary!, [
          'render',
          '--engine-dir',
          engineDir!,
          '--assets',
          assets,
          '--icu',
          icu!,
          '--dpr',
          ratio,
          '--out',
          out,
        ]);
        expect(render.exitCode, 0, reason: '${render.stderr}');
        expect(
          '${render.stderr}',
          isNot(contains('pixel ratio was invalid')),
          reason: '--dpr $ratio',
        );
        expect(File(out).existsSync(), isTrue);
      }
    },
    skip: ready ? false : 'build the runner and example first',
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
        // Frames after the resizes keep coming through the latest set's
        // buffers: the runner takes their releases, named by that set's
        // generation (#135). Four taps, four frames, more than the set
        // holds without them.
        final before = client.sharedFrames;
        var box = _red;
        for (var tap = 0; tap < 4; tap++) {
          for (final (phase, buttons) in [
            (PointerPhase.POINTER_PHASE_DOWN, 1),
            (PointerPhase.POINTER_PHASE_UP, 0),
          ]) {
            client.sendPointer(
              PointerEvent(
                phase: phase,
                x: 197,
                y: 435,
                buttons: Int64(buttons),
                device: PointerDevice.POINTER_DEVICE_MOUSE,
                pointerId: 1,
              ),
            );
          }
          box = switch (box) {
            _red => _green,
            _ => _red,
          };
          final want = box;
          await client.frames
              .firstWhere((f) => f.width == 395 && _pixel(f, 197, 390) == want)
              .timeout(const Duration(seconds: 10));
        }
        if (!Platform.isWindows) {
          expect(client.sharedFrames - before, greaterThanOrEqualTo(4));
        }
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
  // #117: Metal aborted on a side over 16,384 pixels. A frame too large is
  // scaled down to fit, its pixel ratio with it, and the app goes on.
  test(
    'a resize past the GPU\'s limit is scaled down, not fatal',
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
        client.resize(16000, 400, 1);
        // 8192 / 16000 of each side: 8192 by 205.
        final scaled = await client.frames
            .firstWhere((f) => f.width == 8192)
            .timeout(const Duration(seconds: 15));
        expect(scaled.height, 205);
        expect(_pixel(scaled, 3, 3), _blue);
        // The host's pointer stays in the size it asked for: a tap on the
        // box, at the middle of 16000x400, lands on it (#130).
        for (final (phase, buttons) in [
          (PointerPhase.POINTER_PHASE_DOWN, 1),
          (PointerPhase.POINTER_PHASE_UP, 0),
        ]) {
          client.sendPointer(
            PointerEvent(
              phase: phase,
              x: 8000,
              y: 200,
              buttons: Int64(buttons),
              device: PointerDevice.POINTER_DEVICE_MOUSE,
              pointerId: 1,
            ),
          );
        }
        // Checked left of the box's centre, clear of its label: at this
        // pixel ratio a glyph can cover the centre, as on Linux's fonts.
        await client.frames
            .firstWhere(
              (f) => f.width == 8192 && _pixel(f, 4048, 102) == _green,
            )
            .timeout(const Duration(seconds: 10));
        client.resize(395, 870, 1);
        await client.frames
            .firstWhere((f) => f.width == 395 && f.height == 870)
            .timeout(const Duration(seconds: 10));
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
}

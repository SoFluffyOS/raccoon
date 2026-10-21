// Drives the real runner with the example app: frame pixels, then a tap that
// turns the box green. Skipped when the runner or its inputs are not built;
// see native/raccoon_runner/tool/render_example.sh.

import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:path/path.dart' as p;
import 'package:raccoon/raccoon.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

const _blue = (r: 0x1E, g: 0x88, b: 0xE5);
const _red = (r: 0xE5, g: 0x39, b: 0x35);
const _green = (r: 0x43, g: 0xA0, b: 0x47);

({int r, int g, int b}) _pixel(Frame frame, int x, int y) {
  final offset = y * frame.rowBytes + x * 4;
  return (
    r: frame.pixels[offset + 2],
    g: frame.pixels[offset + 1],
    b: frame.pixels[offset],
  );
}

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
  final engineDir =
      environment['RACCOON_ENGINE_DIR'] ??
      _firstEngineDir(
        p.join(environment['HOME'] ?? '', '.cache', 'raccoon', 'engines'),
      );
  final icu = _firstExisting([environment['RACCOON_ICU'] ?? '', _sdkIcu()]);
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

        final frame = await client.frames.first.timeout(
          const Duration(seconds: 15),
        );
        expect(frame.width, 800);
        expect(frame.height, 600);
        expect(frame.format, PixelFormat.PIXEL_FORMAT_BGRA8888);
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
}

String? _firstEngineDir(String cache) {
  final root = Directory(cache);
  if (!root.existsSync()) return null;
  for (final revision in root.listSync().whereType<Directory>()) {
    final dir = p.join(revision.path, 'linux-x64');
    if (File(p.join(dir, 'libflutter_engine.so')).existsSync()) return dir;
  }
  return null;
}

String _sdkIcu() {
  final flutter = Platform.environment['FLUTTER_ROOT'];
  if (flutter != null) {
    return p.join(
      flutter,
      'bin',
      'cache',
      'artifacts',
      'engine',
      'linux-x64',
      'icudtl.dat',
    );
  }
  final home = Platform.environment['HOME'] ?? '';
  return p.join(
    home,
    'fvm',
    'default',
    'bin',
    'cache',
    'artifacts',
    'engine',
    'linux-x64',
    'icudtl.dat',
  );
}

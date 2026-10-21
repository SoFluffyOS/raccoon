// Measures the frame path through the socket: starts a runner on an app
// bundle, resizes it, and counts frames, bytes and CPU for a few seconds.
//
//   dart run raccoon_runtime:raccoon_bench --runner B --engine-dir D --assets A --icu I
//       [--width 1200] [--height 800] [--seconds 5]

import 'dart:io';

import 'package:raccoon_runtime/raccoon_runtime.dart';

Future<void> main(List<String> arguments) async {
  final options = <String, String>{};
  for (var i = 0; i + 1 < arguments.length; i += 2) {
    options[arguments[i].replaceFirst('--', '')] = arguments[i + 1];
  }
  final runnerBinary = options['runner'];
  final engineDir = options['engine-dir'];
  final assets = options['assets'];
  final icu = options['icu'];
  if (runnerBinary == null ||
      engineDir == null ||
      assets == null ||
      icu == null) {
    stderr.writeln(
      'usage: raccoon_bench --runner B --engine-dir D --assets A --icu I [--width N] [--height N] [--seconds N]',
    );
    exitCode = 2;
    return;
  }
  final width = int.parse(options['width'] ?? '1200');
  final height = int.parse(options['height'] ?? '800');
  final seconds = int.parse(options['seconds'] ?? '5');

  final temp = Directory.systemTemp.createTempSync('raccoon_bench');
  final endpoint = UnixSocketEndpoint('${temp.path}/runner.sock');
  final runner = await RunnerProcess.start(
    RunnerLaunch(
      runnerBinary: runnerBinary,
      engineDir: engineDir,
      assets: assets,
      icuData: icu,
      endpoint: endpoint,
      width: width,
      height: height,
    ),
  );
  final client = await RunnerClient.connect(endpoint);
  await client.frames.first.timeout(const Duration(seconds: 15));

  var frames = 0;
  var bytes = 0;
  final runnerCpuStart = _cpuTicks(runner.pid);
  final selfCpuStart = _cpuTicks(pid);
  final clock = Stopwatch()..start();
  final subscription = client.frames.listen((frame) {
    frames++;
    bytes += frame.pixels.length;
  });
  await Future<void>.delayed(Duration(seconds: seconds));
  clock.stop();
  await subscription.cancel();
  final elapsed = clock.elapsedMilliseconds / 1000;
  final runnerCpu =
      (_cpuTicks(runner.pid) - runnerCpuStart) /
      _ticksPerSecond /
      elapsed *
      100;
  final selfCpu =
      (_cpuTicks(pid) - selfCpuStart) / _ticksPerSecond / elapsed * 100;

  stdout
    ..writeln('frame size: ${width}x$height, ${width * height * 4 ~/ 1024} KiB')
    ..writeln(
      'frames: $frames in ${elapsed.toStringAsFixed(1)} s = ${(frames / elapsed).toStringAsFixed(1)} fps',
    )
    ..writeln(
      'bytes: ${(bytes / elapsed / 1024 / 1024).toStringAsFixed(0)} MiB/s',
    )
    ..writeln(
      'runner cpu: ${runnerCpu.toStringAsFixed(0)}% of one core (engine threads included)',
    )
    ..writeln(
      'client cpu: ${selfCpu.toStringAsFixed(0)}% of one core (this Dart process)',
    );

  client.shutdown();
  await client.close();
  final exit = await runner.exitCode.timeout(
    const Duration(seconds: 10),
    onTimeout: () {
      runner.kill();
      return -1;
    },
  );
  stdout.writeln('runner exit: $exit');
  temp.deleteSync(recursive: true);
}

const _ticksPerSecond = 100;

int _cpuTicks(int processId) {
  final stat = File('/proc/$processId/stat').readAsStringSync();
  final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
  return int.parse(fields[11]) + int.parse(fields[12]);
}

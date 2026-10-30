// Stand-in runners are shell scripts.
@TestOn('!windows')
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('raccoon_process'));
  tearDown(() => temp.deleteSync(recursive: true));

  /// A stand-in runner: a shell script.
  RunnerLaunch launchOf(String script) {
    final binary = p.join(temp.path, 'runner');
    File(binary).writeAsStringSync('#!/bin/sh\n$script\n');
    Process.runSync('chmod', ['+x', binary]);
    return RunnerLaunch(
      runnerBinary: binary,
      engineDir: temp.path,
      assets: temp.path,
      icuData: temp.path,
      endpoint: UnixSocketEndpoint(p.join(temp.path, 'app.sock')),
    );
  }

  // #134: a runner that died at once cost the whole timeout, and said
  // nothing of why.
  test(
    'a runner that exits before it listens fails at once, saying why',
    () async {
      final started = DateTime.now();
      await expectLater(
        RunnerProcess.start(
          launchOf('echo "no engine in the engine dir" >&2; exit 3'),
        ),
        throwsA(
          isA<RunnerExited>()
              .having((e) => e.exitCode, 'exitCode', 3)
              .having(
                (e) => e.lastLines,
                'lastLines',
                contains('no engine in the engine dir'),
              ),
        ),
      );
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 5)),
      );
    },
  );

  test(
    'output that is not UTF-8 does not stop the runner being followed',
    () async {
      final runner = await RunnerProcess.start(
        launchOf(
          r"printf '\377\376 bad bytes\n🦝 listening on x\n'; exec sleep 30",
        ),
      );
      addTearDown(runner.kill);
      // Kept, for one that stops answering.
      expect(runner.lastLines.last, '🦝 listening on x');
      final stdoutDone = runner.stdout.toList();
      final vmService = runner.vmServiceUri;
      runner.kill();
      expect(await runner.exitCode, isNot(0));
      expect(
        await stdoutDone.timeout(const Duration(seconds: 5)),
        isA<List<String>>(),
      );
      await expectLater(vmService, throwsA(isA<RunnerExited>()));
    },
  );

  test(
    'a runner that times out is killed, though it ignores SIGTERM',
    () async {
      // #230: one stuck before it listens was sent SIGTERM once and left
      // alive, to take the socket path from the next runner later.
      final pidFile = p.join(temp.path, 'pid');
      await expectLater(
        RunnerProcess.start(
          launchOf("trap '' TERM; echo \$\$ > '$pidFile'; exec sleep 30"),
          // Long enough for the shell to start on a loaded machine and
          // write its pid before it is killed (#308).
          timeout: const Duration(seconds: 3),
        ),
        throwsA(isA<TimeoutException>()),
      );
      final pid = File(pidFile).readAsStringSync().trim();
      expect(Process.runSync('kill', ['-0', pid]).exitCode, isNot(0));
    },
  );
}

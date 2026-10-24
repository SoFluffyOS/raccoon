import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:raccoon_runtime/src/runner_endpoint.dart';

/// Starts a process; the IDE passes its own launcher, tests use [Process.start].
typedef ProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

/// How to start a runner for one app bundle.
final class RunnerLaunch {
  const RunnerLaunch({
    required this.runnerBinary,
    required this.engineDir,
    required this.assets,
    required this.icuData,
    required this.endpoint,
    this.width = 800,
    this.height = 600,
    this.pixelRatio = 1.0,
    this.dataDir,
    this.plugins,
    this.cameraSource,
  });

  final String runnerBinary;
  final String engineDir;
  final String assets;
  final String icuData;
  final UnixSocketEndpoint endpoint;
  final int width;
  final int height;
  final double pixelRatio;

  /// Where the app's files live: its preferences, and on Linux the XDG
  /// base directories the Dart-only plugins use. Without one every app
  /// hosted by this runner binary shares the runner's own.
  final String? dataDir;

  /// A manifest of native plugins the runner loads, as the device helper
  /// writes one: `{"plugins": [{"name", "library", "symbol"}]}`.
  final String? plugins;

  /// A PNG or JPEG the app's camera shows in place of the runner's test
  /// pattern; on Windows a video too, played in a loop.
  final String? cameraSource;

  List<String> get arguments => [
    'serve',
    '--engine-dir',
    engineDir,
    '--assets',
    assets,
    '--icu',
    icuData,
    '--socket',
    endpoint.path,
    if (dataDir case final dir?) ...['--data-dir', dir],
    if (plugins case final manifest?) ...['--plugins', manifest],
    if (cameraSource case final source?) ...['--camera-source', source],
    '--width',
    '$width',
    '--height',
    '$height',
    '--dpr',
    '$pixelRatio',
  ];
}

/// A running runner process. Its stdout carries the engine's log lines, among
/// them the Dart VM service line the Flutter tool looks for.
final class RunnerProcess {
  RunnerProcess._(this._process, this.launch) {
    // Lenient: an app or a plugin can print bytes that are not UTF-8.
    _process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          _onStdoutLine,
          onDone: () {
            _stdoutRead.complete();
            unawaited(_stdout.close());
          },
        );
    _process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          _onStderrLine,
          onDone: () {
            _stderrRead.complete();
            unawaited(_stderr.close());
          },
        );
    _vmService.future.ignore();
    unawaited(_process.exitCode.then(_onExit));
  }

  /// Starts the runner and waits until it listens on its socket.
  static Future<RunnerProcess> start(
    RunnerLaunch launch, {
    ProcessStarter startProcess = Process.start,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final process = await startProcess(launch.runnerBinary, launch.arguments);
    final runner = RunnerProcess._(process, launch);
    await runner._listening.future.timeout(
      timeout,
      onTimeout: () {
        runner.kill();
        throw TimeoutException('runner did not start listening', timeout);
      },
    );
    return runner;
  }

  final Process _process;
  final RunnerLaunch launch;
  final _listening = Completer<void>();
  final _vmService = Completer<String>();
  final _stdout = StreamController<String>.broadcast();
  final _stderr = StreamController<String>.broadcast();

  final _stdoutRead = Completer<void>();
  final _stderrRead = Completer<void>();

  /// The last lines, to say why a runner that exited at once did.
  final _lastLines = <String>[];
  static const _keptLines = 20;

  // The runner's lines start with 🦝 (#94), and did with `raccoon_runner:`.
  static const _prefixes = ['🦝 ', 'raccoon_runner: '];
  static const _vmServicePrefix = 'The Dart VM service is listening on ';
  String? _renderer;

  /// The engine's stdout lines.
  Stream<String> get stdout => _stdout.stream;

  /// The runner's own diagnostics.
  Stream<String> get stderr => _stderr.stream;

  /// The Dart VM service URI, once the engine printed it.
  Future<String> get vmServiceUri => _vmService.future;

  /// What rasterizes: `software`, `gl` or `metal`, once the runner said;
  /// it says before it listens, so this is known after [start].
  String? get renderer => _renderer;

  int get pid => _process.pid;

  Future<int> get exitCode => _process.exitCode;

  bool kill() => _process.kill();

  void _onStdoutLine(String line) {
    final said = switch (_prefixes.where(line.startsWith).firstOrNull) {
      final prefix? => line.substring(prefix.length),
      null => null,
    };
    if (said != null &&
        said.startsWith('listening on ') &&
        !_listening.isCompleted) {
      _listening.complete();
    }
    if (said != null && said.startsWith('renderer ')) {
      _renderer = said.substring('renderer '.length).split(' ').first;
    }
    if (line.startsWith(_vmServicePrefix) && !_vmService.isCompleted) {
      _vmService.complete(line.substring(_vmServicePrefix.length).trim());
    }
    _keep(line);
    _stdout.add(line);
  }

  void _onStderrLine(String line) {
    _keep(line);
    _stderr.add(line);
  }

  void _keep(String line) {
    _lastLines.add(line);
    if (_lastLines.length > _keptLines) _lastLines.removeAt(0);
  }

  /// A runner that exits before it listens fails [start] at once, with its
  /// last words, rather than after the whole timeout (#134).
  Future<void> _onExit(int code) async {
    // The exit can come before its last lines are read; they say why.
    await Future.wait([
      _stdoutRead.future,
      _stderrRead.future,
    ]).timeout(const Duration(seconds: 1), onTimeout: () => const []);
    if (!_listening.isCompleted) {
      _listening.completeError(
        RunnerExited(code, List.unmodifiable(_lastLines)),
      );
    }
    if (!_vmService.isCompleted) _vmService.completeError(RunnerExited(code));
  }
}

/// The runner process ended before it got as far as asked.
final class RunnerExited implements Exception {
  const RunnerExited(this.exitCode, [this.lastLines = const []]);

  final int exitCode;

  /// What it printed last, stdout and stderr together.
  final List<String> lastLines;

  @override
  String toString() => switch (lastLines) {
    [] => 'the runner exited with code $exitCode',
    _ => 'the runner exited with code $exitCode:\n${lastLines.join('\n')}',
  };
}

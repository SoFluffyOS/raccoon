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
    _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onStdoutLine);
    _process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_stderr.add);
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

  static const _listeningPrefix = 'raccoon_runner: listening on ';
  static const _rendererPrefix = 'raccoon_runner: renderer ';
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
    if (line.startsWith(_listeningPrefix) && !_listening.isCompleted) {
      _listening.complete();
    }
    if (line.startsWith(_rendererPrefix)) {
      _renderer = line.substring(_rendererPrefix.length).split(' ').first;
    }
    if (line.startsWith(_vmServicePrefix) && !_vmService.isCompleted) {
      _vmService.complete(line.substring(_vmServicePrefix.length).trim());
    }
    _stdout.add(line);
  }
}

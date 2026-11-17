import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:raccoon/raccoon.dart';
import 'package:raccoon_runtime/src/device_input.dart';
import 'package:raccoon_runtime/src/frame_capture.dart';
import 'package:raccoon_runtime/src/frame_image.dart';
import 'package:raccoon_runtime/src/raccoon_device.dart';
import 'package:raccoon_runtime/src/runner_client.dart';
import 'package:raccoon_runtime/src/runner_discovery.dart';
import 'package:raccoon_runtime/src/runner_endpoint.dart';
import 'package:raccoon_runtime/src/runner_process.dart';
import 'package:raccoon_runtime/src/runtime_store.dart';

/// A logical size and the pixel ratio it is shown at: `390x844@3`.
typedef DeviceSize = ({double width, double height, double pixelRatio});

/// An app running on a Raccoon device, for tests and tools that drive it:
/// launch it, send taps, drags, scrolls and keys in logical pixels, take its
/// frames as images and PNGs, compare them with goldens, read its log, hot
/// reload, stop.
///
/// [launch] runs a project the way the hosts do, through
/// `flutter run -d <device> --machine`, and attaches to the runner as its
/// client; [launchBundle] starts the runner itself on a bundle built
/// already. A Raccoon device needs no window and no display.
///
/// ```dart
/// final phone = await RaccoonTestDevice.launch('path/to/app');
/// await phone.tap(195, 422);
/// final frame = await phone.frame();
/// await frame.expectGolden('goldens/phone.png');
/// await phone.stop();
/// ```
final class RaccoonTestDevice {
  RaccoonTestDevice._({
    required this.deviceId,
    required DeviceSize size,
    required this.client,
    required this.vmServiceUri,
    required _Logs logs,
    _FlutterRun? run,
    RunnerProcess? runner,
    Directory? temporary,
  }) : _size = size,
       _logs = logs,
       _run = run,
       _runner = runner,
       _temporary = temporary;

  /// The Flutter tool's id of the device: `raccoon-phone`.
  final String deviceId;

  /// The app's logical size and pixel ratio. Input is in these logical
  /// pixels, and frames are this size times the ratio; [resize] changes it.
  DeviceSize get size => _size;
  DeviceSize _size;

  /// The connection to the runner, for what this class does not wrap:
  /// semantics, settings, the lifecycle, platform channels.
  final RunnerClient client;

  /// The app's Dart VM service, `http://127.0.0.1:<port>/<token>/`: what
  /// DevTools, `package:vm_service` and an agent's MCP server attach to.
  final String vmServiceUri;

  /// [vmServiceUri] as a WebSocket, `ws://127.0.0.1:<port>/<token>/ws`:
  /// what `package:vm_service`'s `vmServiceConnectUri` and marionette_mcp's
  /// `connect` take.
  String get vmServiceWebSocketUri {
    final uri = Uri.parse(vmServiceUri);
    final path = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
    return uri
        .replace(
          scheme: uri.scheme == 'https' ? 'wss' : 'ws',
          path: '${path}ws',
        )
        .toString();
  }

  /// From the call to launch to the first frame at the device's size.
  Duration get startup => _startup;
  var _startup = Duration.zero;

  final _Logs _logs;
  final _FlutterRun? _run;
  final RunnerProcess? _runner;
  final Directory? _temporary;
  var _stopped = false;

  /// The built-in sized devices: phone, tablet and desktop.
  static const presets = ['raccoon-phone', 'raccoon-tablet', 'raccoon-desktop'];

  /// The size a device without one of its own (`raccoon`, `raccoon-2`) is
  /// given, unless the launch names one.
  static const DeviceSize defaultSize = (
    width: 800,
    height: 600,
    pixelRatio: 1,
  );

  /// Runs the project at [projectDir] on [device] through
  /// `flutter run -d <device> --machine`, as the simulator and Lumide do,
  /// and attaches to its runner. The device must be registered
  /// (`raccoon_device setup`, `raccoon_device add phone`).
  ///
  /// [target] is the entry point (`lib/main.dart` by default); [size]
  /// resizes the app after it starts, and is needed for nothing but a
  /// device without a size of its own, which otherwise gets
  /// [defaultSize]. [gpuBuffers] takes frames as the hosts do on a GPU,
  /// in a ring of GPU buffers, and reads pixels back only for [frame].
  /// [headless] (the default) tells the runner no host is coming
  /// (`RACCOON_HEADLESS=1`). [flutter] is the tool to run, [flutterArgs]
  /// go after its own, [environment] adds to the tool's.
  static Future<RaccoonTestDevice> launch(
    String projectDir, {
    String device = 'raccoon-phone',
    String? target,
    DeviceSize? size,
    bool gpuBuffers = false,
    bool headless = true,
    String flutter = 'flutter',
    List<String> flutterArgs = const [],
    Map<String, String> environment = const {},
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final clock = Stopwatch()..start();
    final key = _instanceOf(device);
    final known = _sizeOf(key, size);
    final appName = _pubspecName(projectDir);
    final logs = _Logs();
    final run = await _FlutterRun.start(
      flutter,
      [
        'run',
        '-d',
        device,
        '--machine',
        if (target != null) ...['--target', target],
        ...flutterArgs,
      ],
      workingDirectory: projectDir,
      environment: {...environment, if (headless) 'RACCOON_HEADLESS': '1'},
      logs: logs,
    );
    try {
      final vmService = await run.started.timeout(timeout);
      final socketName = key == '1' ? appName : '$appName@$key';
      final endpoint = await _findSocket(socketName, run.exited);
      final client = await _attach(endpoint, gpuBuffers);
      final testDevice = RaccoonTestDevice._(
        deviceId: device,
        size: known,
        client: client,
        vmServiceUri: vmService,
        logs: logs,
        run: run,
      );
      await testDevice._settleSize(size != null || !_hasOwnSize(key));
      return testDevice.._startup = clock.elapsed;
    } on Object {
      await run.stop();
      rethrow;
    }
  }

  /// Several devices at once, the same project on each, each through its
  /// own `flutter run`, back in [devices]' order. The first builds the app
  /// alone, the rest then start together on its build: tools building
  /// into one project's `build/` at once overwrite each other's bundle.
  /// One that fails stops the others.
  static Future<List<RaccoonTestDevice>> launchAll(
    String projectDir, {
    List<String> devices = presets,
    String? target,
    bool gpuBuffers = false,
    bool headless = true,
    String flutter = 'flutter',
    List<String> flutterArgs = const [],
    Map<String, String> environment = const {},
    Duration timeout = const Duration(minutes: 5),
  }) async {
    Future<RaccoonTestDevice> one(String device) => launch(
      projectDir,
      device: device,
      target: target,
      gpuBuffers: gpuBuffers,
      headless: headless,
      flutter: flutter,
      flutterArgs: flutterArgs,
      environment: environment,
      timeout: timeout,
    );
    if (devices.isEmpty) return [];
    final first = await one(devices.first);
    final launches = [
      Future.value(first),
      for (final device in devices.skip(1)) one(device),
    ];
    final settled = await Future.wait([
      for (final launch in launches)
        launch.then<Object>((device) => device, onError: (Object e) => e),
    ]);
    final failure = settled.whereType<Object>().where(
      (value) => value is! RaccoonTestDevice,
    );
    if (failure.isEmpty) return settled.cast<RaccoonTestDevice>();
    await Future.wait(
      settled.whereType<RaccoonTestDevice>().map((d) => d.stop()),
    );
    throw failure.first;
  }

  /// Starts the runner itself on a bundle built already
  /// (`flutter build bundle`, its `build/flutter_assets`), at [device]'s
  /// size or [size], and attaches to it: no Flutter tool, so no hot
  /// reload. [runnerBinary] defaults to `RACCOON_RUNNER`; the engine comes
  /// from the runtime store for the SDK on the PATH (downloaded when
  /// missing) unless [engineDir] names one, and the ICU data from that
  /// SDK unless [icuData] does.
  static Future<RaccoonTestDevice> launchBundle(
    String assets, {
    String device = 'raccoon-phone',
    DeviceSize? size,
    String? runnerBinary,
    String? engineDir,
    String? icuData,
    String? dataDir,
    String? plugins,
    bool gpuBuffers = false,
    bool headless = true,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final clock = Stopwatch()..start();
    final key = _instanceOf(device);
    final known = _sizeOf(key, size);
    final environment = Platform.environment;
    final binary = runnerBinary ?? environment['RACCOON_RUNNER'];
    if (binary == null || binary.isEmpty) {
      throw ArgumentError('no runner: pass runnerBinary or set RACCOON_RUNNER');
    }
    final sdk = environment['FLUTTER_ROOT'] ?? RuntimeStore.sdkRootOnPath();
    final engine =
        engineDir ??
        environment['RACCOON_ENGINE_DIR'] ??
        await _engineOf(sdk, environment);
    final icu =
        icuData ??
        environment['RACCOON_ICU'] ??
        (sdk == null ? null : RuntimeStore.icuDataOfSdk(sdk));
    if (icu == null) throw StateError('no ICU data: no Flutter SDK found');
    final temporary = Directory.systemTemp.createTempSync('raccoon_device');
    final logs = _Logs();
    RunnerProcess? runner;
    try {
      final endpoint = UnixSocketEndpoint(p.join(temporary.path, 'app.sock'));
      runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary,
          engineDir: engine,
          assets: assets,
          icuData: icu,
          endpoint: endpoint,
          width: (known.width * known.pixelRatio).round(),
          height: (known.height * known.pixelRatio).round(),
          pixelRatio: known.pixelRatio,
          dataDir: dataDir ?? temporary.path,
          plugins: plugins,
          headless: headless,
        ),
        timeout: timeout,
      );
      final started = runner;
      started.stdout.listen(logs.add);
      started.stderr.listen(logs.add);
      for (final line in started.lastLines) {
        logs.add(line);
      }
      Future<RaccoonTestDevice> attach() async {
        final vmService = await started.vmServiceUri.timeout(timeout);
        final client = await _attach(endpoint, gpuBuffers);
        final testDevice = RaccoonTestDevice._(
          deviceId: device,
          size: known,
          client: client,
          vmServiceUri: vmService,
          logs: logs,
          runner: started,
          temporary: temporary,
        );
        await testDevice._settleSize(false);
        return testDevice;
      }

      // A runner that ends before the first frame, as one whose app the
      // engine would not start does (#408), fails the launch at once with
      // its last words, rather than with what its going broke or after
      // the frame's whole wait.
      final ended = started.exited.then<RaccoonTestDevice>(
        (exited) => throw exited,
      );
      final RaccoonTestDevice testDevice;
      try {
        testDevice = await Future.any([attach(), ended]);
      } on Object {
        // The runner's own end, with its last lines, over what its going
        // broke: a VM service never printed, a socket gone, no frame.
        final exited = await started.exited
            .then<RunnerExited?>((exited) => exited)
            .timeout(const Duration(seconds: 1), onTimeout: () => null);
        if (exited != null) throw exited;
        rethrow;
      }
      return testDevice.._startup = clock.elapsed;
    } on Object {
      runner?.kill();
      if (runner != null) await runner.exitCode;
      temporary.deleteSync(recursive: true);
      rethrow;
    }
  }

  /// The app's log and the runner's, line by line, from here on: what the
  /// app prints, the engine's lines, and the runner's own `🦝` lines.
  Stream<String> get logs => _logs.stream;

  /// Every log line so far, from the start of the run.
  List<String> get logLines => List.unmodifiable(_logs.lines);

  /// The first log line from now matching [pattern], within [timeout].
  Future<String> waitForLog(
    Pattern pattern, {
    Duration timeout = const Duration(seconds: 10),
  }) => logs.firstWhere((line) => line.contains(pattern)).timeout(timeout);

  /// Input in logical pixels: what [tap] and the rest send through.
  late final RaccoonInput input = RaccoonInput(
    client,
    pixelRatio: () => _size.pixelRatio,
    name: deviceId,
  );

  /// Taps at ([x], [y]) in logical pixels.
  Future<void> tap(double x, double y) => input.tap(x, y);

  /// Presses at ([x], [y]) for [hold], longer than Flutter's long press
  /// takes (500 ms).
  Future<void> longPress(
    double x,
    double y, {
    Duration hold = const Duration(milliseconds: 650),
  }) => input.longPress(x, y, hold: hold);

  /// Drags a finger from ([fromX], [fromY]) to ([toX], [toY]) over
  /// [duration], in [steps] moves, then lifts it: a fling when short and
  /// fast, a pan when slow.
  Future<void> drag(
    double fromX,
    double fromY,
    double toX,
    double toY, {
    Duration duration = const Duration(milliseconds: 300),
    int steps = 20,
  }) => input.drag(fromX, fromY, toX, toY, duration: duration, steps: steps);

  /// Turns a mouse wheel over ([x], [y]) by [dx], [dy] logical pixels:
  /// positive [dy] scrolls down the content, as a wheel turned towards the
  /// user does.
  Future<void> scroll(double x, double y, {double dx = 0, double dy = 0}) =>
      input.scroll(x, y, dx: dx, dy: dy);

  /// Types [text] into the text field that has the focus, in place of its
  /// selection, as a host's input method does. Tap the field first.
  Future<void> typeText(
    String text, {
    Duration focusWait = const Duration(seconds: 5),
  }) => input.typeText(text, focusWait: focusWait);

  /// Presses and releases [key], with [modifiers] held around it.
  Future<void> pressKey(
    RaccoonKey key, {
    List<RaccoonKey> modifiers = const [],
  }) => input.pressKey(key, modifiers: modifiers);

  /// Gives the app a new logical size and pixel ratio, as a host's board
  /// does, and waits for its first frame at that size.
  Future<void> resize(DeviceSize size) async {
    _size = size;
    await _settleSize(true);
  }

  /// The app's frame once it settles: the latest frame after no new one
  /// has come for [settle], or the latest at [timeout] for an app that
  /// never stops animating. Taken after input, it shows what the input did.
  Future<RaccoonFrame> frame({
    Duration settle = const Duration(milliseconds: 250),
    Duration timeout = const Duration(seconds: 5),
  }) => settledFrame(
    client,
    pixelRatio: _size.pixelRatio,
    settle: settle,
    timeout: timeout,
    name: deviceId,
  );

  /// Hot reloads the app: its code changed on disk, its state stays. Only
  /// for an app [launch]ed through the Flutter tool. Returns once the app
  /// has drawn after it.
  Future<void> hotReload() => _restart(full: false);

  /// Hot restarts the app: its code reloads and its state starts again.
  /// Only for an app [launch]ed through the Flutter tool. Returns once the
  /// app has drawn after it.
  Future<void> hotRestart() => _restart(full: true);

  /// Stops the app and its runner, and with them the Flutter tool's run.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    final run = _run;
    final runner = _runner;
    if (run != null) {
      await run.stop();
    } else if (runner != null) {
      client.shutdown();
      final code = await runner.exitCode
          .then<int?>((code) => code)
          .timeout(const Duration(seconds: 10), onTimeout: () => null);
      if (code == null) {
        runner.kill();
        await runner.exitCode;
      }
    }
    await client.close();
    _temporary?.deleteSync(recursive: true);
  }

  Future<void> _restart({required bool full}) async {
    final run = _run;
    if (run == null) {
      throw UnsupportedError(
        'a bundle started without the Flutter tool has no hot '
        '${full ? 'restart' : 'reload'}: use launch',
      );
    }
    // The app draws once it has reloaded or restarted, as the tool answers
    // or after: until that frame, [frame] would show the app as before.
    final drawn = client.messages
        .where((message) => message.hasFrame())
        .first
        .timeout(const Duration(seconds: 10), onTimeout: () => RunnerMessage());
    drawn.ignore();
    await run.restart(full: full);
    await drawn;
  }

  /// Sizes the app as [size] says when [resize], and waits for its first
  /// frame at that size.
  Future<void> _settleSize(bool resize) async {
    final width = (size.width * size.pixelRatio).round();
    final height = (size.height * size.pixelRatio).round();
    if (resize) client.resize(width, height, size.pixelRatio);
    await client.frames
        .where((frame) => frame.width == width && frame.height == height)
        .first
        .timeout(
          const Duration(seconds: 30),
          onTimeout:
              () =>
                  throw TimeoutException(
                    'no ${width}x$height frame from $deviceId',
                  ),
        );
  }

  static String _instanceOf(String device) => switch (device) {
    'raccoon' => '1',
    _ when device.startsWith('raccoon-') && device.length > 8 => device
        .substring(8),
    _ => throw ArgumentError.value(device, 'device', 'not a Raccoon device'),
  };

  static bool _hasOwnSize(String key) =>
      RaccoonDevice.forKey(key)?.hasSize ?? false;

  static DeviceSize _sizeOf(String key, DeviceSize? asked) {
    if (asked != null) return asked;
    final device = RaccoonDevice.forKey(key);
    if (device case RaccoonDevice(:final int width, :final int height)) {
      return (
        width: width.toDouble(),
        height: height.toDouble(),
        pixelRatio: device.pixelRatio ?? 1,
      );
    }
    return defaultSize;
  }

  static String _pubspecName(String projectDir) {
    final pubspec = File(p.join(projectDir, 'pubspec.yaml'));
    final name = RegExp(
      r'^name:\s*([A-Za-z0-9_]+)',
      multiLine: true,
    ).firstMatch(pubspec.readAsStringSync())?.group(1);
    if (name == null) throw StateError('no name in ${pubspec.path}');
    return name;
  }

  static Future<String> _engineOf(
    String? sdk,
    Map<String, String> environment,
  ) async {
    final revision = sdk == null ? null : RuntimeStore.revisionOfSdk(sdk);
    if (revision == null) throw StateError('no Flutter SDK found');
    final runtime = await RuntimeStore.forHost(environment).ensure(revision);
    return runtime.directory;
  }

  /// The runner's socket for [appName]: it listens before the tool says
  /// the app started.
  static Future<UnixSocketEndpoint> _findSocket(
    String appName,
    Future<void> exited,
  ) async {
    final discovery = RunnerDiscovery.forHost(
      operatingSystem: Platform.operatingSystem,
      environment: Platform.environment,
      temporaryDirectory: Directory.systemTemp.path,
    );
    var gone = false;
    unawaited(exited.whenComplete(() => gone = true));
    final clock = Stopwatch()..start();
    while (clock.elapsed < const Duration(seconds: 10) && !gone) {
      for (final endpoint in discovery.list()) {
        if (RunnerDiscovery.appNameOf(endpoint) == appName) return endpoint;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw StateError('no socket for $appName in ${discovery.directory}');
  }

  static Future<RunnerClient> _attach(
    UnixSocketEndpoint endpoint,
    bool gpuBuffers,
  ) async {
    // A host following the socket directory may have taken the runner; a
    // client that claims it takes it from a host that only yields.
    final client = await RunnerClient.connect(
      endpoint,
      gpuBuffers: gpuBuffers,
      claims: true,
    );
    await client.hello.timeout(const Duration(seconds: 10));
    if (gpuBuffers) {
      // Nothing shows them: each goes back as it comes, except while
      // [frame] reads pixels.
      client.frames.listen((frame) {
        if (frame.inGpuBuffer && !client.pixelsWanted) {
          client.releaseGpuBuffer(frame.gpuGeneration, frame.bufferIndex);
        }
      }, onError: (Object _) {});
    }
    return client;
  }
}

/// Log lines kept from the start, and streamed.
final class _Logs {
  final lines = <String>[];
  final _controller = StreamController<String>.broadcast();

  Stream<String> get stream => _controller.stream;

  void add(String line) {
    lines.add(line);
    _controller.add(line);
  }
}

/// `flutter run --machine`: its events in, its commands out.
final class _FlutterRun {
  _FlutterRun._(this._process, this._logs) {
    _process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_onLine);
    _process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_log);
    unawaited(
      _process.exitCode.then((code) {
        if (!_started.isCompleted) {
          _started.completeError(
            StateError(
              'flutter run exited with $code before the app started:\n'
              '${_logs.lines.reversed.take(30).toList().reversed.join('\n')}',
            ),
          );
        }
        for (final pending in _pending.values) {
          pending.completeError(StateError('flutter run exited with $code'));
        }
        _pending.clear();
        _exited.complete();
      }),
    );
    _started.future.ignore();
  }

  static Future<_FlutterRun> start(
    String flutter,
    List<String> arguments, {
    required String workingDirectory,
    required Map<String, String> environment,
    required _Logs logs,
  }) async => _FlutterRun._(
    await Process.start(
      flutter,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: Platform.isWindows,
    ),
    logs,
  );

  final Process _process;
  final _Logs _logs;
  final _started = Completer<String>();
  final _exited = Completer<void>();
  final _pending = <int, Completer<Object?>>{};
  String? _appId;
  String? _vmService;
  var _nextId = 1;

  /// The VM service URI once the app started.
  Future<String> get started => _started.future;

  Future<void> get exited => _exited.future;

  void _onLine(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('[{') || !trimmed.endsWith('}]')) {
      _log(line);
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      _logs.add(line);
      return;
    }
    if (decoded case [final Map<String, Object?> message]) {
      _onMessage(message);
    }
  }

  void _onMessage(Map<String, Object?> message) {
    if (message case {'id': final int id} when !message.containsKey('event')) {
      final pending = _pending.remove(id);
      if (pending == null) return;
      if (message['error'] case final error?) {
        pending.completeError(StateError('$error'));
      } else {
        pending.complete(message['result']);
      }
      return;
    }
    final params = switch (message['params']) {
      final Map<String, Object?> map => map,
      _ => const <String, Object?>{},
    };
    switch (message['event']) {
      case 'app.start':
        _appId = params['appId'] as String?;
      case 'app.debugPort':
        _vmService = params['wsUri'] as String?;
      case 'app.started':
        if (!_started.isCompleted) {
          _started.complete(_httpOf(_vmService ?? ''));
        }
      case 'app.log':
        for (final line in const LineSplitter().convert('${params['log']}')) {
          _log(line);
        }
      case 'daemon.logMessage':
        _logs.add('${params['message']}');
      case 'app.stop':
        if (!_started.isCompleted) {
          _started.completeError(
            StateError('the app stopped: ${params['error'] ?? ''}'),
          );
        }
    }
  }

  /// Keeps [line]; one saying the engine could not start fails the
  /// launch, which the tool would wait on for good: it waits for the VM
  /// service of a runner that is gone.
  void _log(String line) {
    _logs.add(line);
    if (!_started.isCompleted && _fatal.any(line.contains)) {
      _started.completeError(
        StateError(
          'the app did not start:\n'
          '${_logs.lines.reversed.take(10).toList().reversed.join('\n')}',
        ),
      );
    }
  }

  /// What the engine and the device helper say when the app cannot start.
  static const _fatal = [
    'Could not launch engine with configuration',
    '🦝 raccoon_runner exited with code',
    '🦝 raccoon_runner died of signal',
  ];

  /// The VM service's HTTP URI from the tool's WebSocket one:
  /// `ws://127.0.0.1:1234/abc=/ws` is `http://127.0.0.1:1234/abc=/`.
  static String _httpOf(String ws) {
    if (ws.isEmpty) return ws;
    final uri = Uri.parse(ws);
    final path =
        uri.path.endsWith('/ws')
            ? uri.path.substring(0, uri.path.length - 2)
            : uri.path;
    return uri
        .replace(scheme: uri.scheme == 'wss' ? 'https' : 'http', path: path)
        .toString();
  }

  Future<Object?> request(String method, Map<String, Object?> params) {
    final id = _nextId++;
    final completer = _pending[id] = Completer<Object?>();
    _process.stdin.writeln(
      jsonEncode([
        {'id': id, 'method': method, 'params': params},
      ]),
    );
    return completer.future;
  }

  Future<void> restart({required bool full}) async {
    final appId = _appId;
    if (appId == null) throw StateError('the app has not started');
    final result = await request('app.restart', {
      'appId': appId,
      'fullRestart': full,
      'pause': false,
      'reason': 'manual',
    }).timeout(const Duration(minutes: 2));
    if (result case {'code': final int code} when code != 0) {
      throw StateError(
        'hot ${full ? 'restart' : 'reload'} failed: '
        '${(result as Map)['message'] ?? code}',
      );
    }
  }

  Future<void> stop() async {
    if (_exited.isCompleted) return;
    final appId = _appId;
    if (appId != null) {
      try {
        await request('app.stop', {
          'appId': appId,
        }).timeout(const Duration(seconds: 10));
      } on Object {
        // Gone already, or not answering: the kill below ends it.
      }
    }
    final ended = await _exited.future
        .then((_) => true)
        .timeout(const Duration(seconds: 10), onTimeout: () => false);
    if (!ended) {
      _process.kill();
      await _exited.future;
    }
  }
}

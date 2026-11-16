import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/raccoon_runtime.dart';

/// Raccoon devices with no host open: each run is a [RaccoonTestDevice],
/// its own `flutter run -d <device> --machine` and a client of its own,
/// nothing on screen. What `raccoon_mcp` falls back to without a simulator,
/// and what CI uses.
final class HeadlessHost implements RaccoonControlHost {
  HeadlessHost({
    this.flutter = 'flutter',
    Map<String, String>? environment,
    this.launch = RaccoonTestDevice.launch,
  }) : environment = environment ?? Platform.environment;

  /// The Flutter tool to run.
  final String flutter;

  final Map<String, String> environment;

  /// Starts a run; [RaccoonTestDevice.launch] but in tests.
  final Future<RaccoonTestDevice> Function(
    String projectDir, {
    String device,
    String? target,
    String flutter,
  })
  launch;

  final _apps = <String, HeadlessApp>{};
  final _starting = <String, Future<HeadlessApp>>{};

  // Runs of one project wait for each other: two tools building into one
  // `build/` at once overwrite each other's bundle.
  final _building = <String, Future<void>>{};

  @override
  String get kind => 'headless';

  @override
  List<RaccoonControlDevice> devices() {
    final file = CustomDevicesFile.forHost(environment);
    return [
      for (final id in file.ids())
        if (RaccoonControlDevice.keyOf(id) != null)
          RaccoonControlDevice.of(
            id,
            label: file.labelOf(id),
            size: file.sizeOf(id),
          ),
    ];
  }

  @override
  List<RaccoonControlApp> apps() => List.unmodifiable(_apps.values);

  @override
  Future<RaccoonControlApp> run(
    String project, {
    required String device,
    String? target,
  }) {
    final directory = p.normalize(p.absolute(project));
    final appName = pubspecName(directory);
    final name = RaccoonControlDevice.appNameOn(appName, device);
    if (_apps[name] case final running?) return Future.value(running);
    if (_starting[name] case final starting?) return starting;
    final before = _building[directory] ?? Future<void>.value();
    final started = before.then((_) async {
      final RaccoonTestDevice launched;
      try {
        launched = await launch(
          directory,
          device: device,
          target: target,
          flutter: flutter,
        );
      } on Object catch (error) {
        throw RaccoonControlError(RaccoonControlError.failed, '$error');
      }
      return _apps[name] = HeadlessApp(name, launched, this);
    });
    _building[directory] = started.then<void>((_) {}, onError: (Object _) {});
    _starting[name] = started;
    unawaited(
      started
          .whenComplete(() => _starting.remove(name))
          .then<void>((_) {}, onError: (Object _) {}),
    );
    return started;
  }

  /// Says what an agent did on stderr: nobody watches a headless run, and
  /// stdout is the MCP client's.
  @override
  void announce(RaccoonControlApp? app, String action) {
    if (!verbose) return;
    stderr.writeln(switch (app) {
      final app? => 'raccoon_mcp: $action on ${app.name}',
      null => 'raccoon_mcp: $action',
    });
  }

  /// Whether [announce] writes to stderr.
  var verbose = false;

  /// Stops every run.
  Future<void> stopAll() async {
    await Future.wait([
      for (final starting in _starting.values)
        starting.then<void>((_) {}, onError: (Object _) {}),
    ]);
    await Future.wait([for (final app in _apps.values.toList()) app.stop()]);
  }

  void _gone(HeadlessApp app) {
    if (identical(_apps[app.name], app)) _apps.remove(app.name);
  }

  /// The `name:` of the pubspec in [directory].
  static String pubspecName(String directory) {
    final pubspec = File(p.join(directory, 'pubspec.yaml'));
    if (!pubspec.existsSync()) {
      throw RaccoonControlError(
        RaccoonControlError.badParams,
        'no pubspec.yaml in $directory',
      );
    }
    final name = RegExp(
      r'^name:\s*([A-Za-z0-9_]+)',
      multiLine: true,
    ).firstMatch(pubspec.readAsStringSync())?.group(1);
    if (name == null) {
      throw RaccoonControlError(
        RaccoonControlError.badParams,
        'no name in ${pubspec.path}',
      );
    }
    return name;
  }
}

/// A [RaccoonTestDevice] as the control calls drive it.
final class HeadlessApp implements RaccoonControlApp {
  HeadlessApp(this.name, this.device, this._host) {
    unawaited(device.client.closed.then((_) => _host._gone(this)));
  }

  @override
  final String name;

  final RaccoonTestDevice device;
  final HeadlessHost _host;

  @override
  RunnerClient get client => device.client;

  @override
  DeviceSize get size => device.size;

  @override
  String get startedBy => 'headless';

  @override
  String? get vmServiceUri => device.vmServiceUri;

  @override
  bool get canReload => true;

  @override
  bool get releasesGpuFrames => true;

  @override
  Future<void> hotReload() => device.hotReload();

  @override
  Future<void> hotRestart() => device.hotRestart();

  @override
  Future<void> stop() async {
    _host._gone(this);
    await device.stop();
  }

  @override
  Future<void> resize(DeviceSize size) => device.resize(size);

  @override
  List<DeviceLogLine> logLines() => [
    for (final line in device.logLines) DeviceLogLine.output(line),
  ];
}

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:raccoon_mcp/src/headless_host.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';

/// Which host the calls go to.
enum HostChoice {
  /// The simulator when one is open, headless otherwise.
  auto,

  /// The simulator; a call fails when none is open.
  simulator,

  /// Headless runs of this process, even with a simulator open.
  headless,
}

/// Where each tool call goes: to the simulator's control endpoint, so the
/// person at its board sees it, or to runs of this process with no host
/// at all. The calls and their results are the same either way, and each
/// result says which in `host`.
final class RaccoonBridge {
  RaccoonBridge({
    this.choice = HostChoice.auto,
    String flutter = 'flutter',
    Map<String, String>? environment,
    String? workingDirectory,
    Future<RaccoonControlClient?> Function()? discover,
    HeadlessHost? headless,
  }) : _environment = environment ?? Platform.environment,
       _workingDirectory = workingDirectory ?? Directory.current.path,
       _discover = discover,
       _headlessHost = headless ?? HeadlessHost(flutter: flutter);

  final HostChoice choice;
  final Map<String, String> _environment;
  final String _workingDirectory;
  final Future<RaccoonControlClient?> Function()? _discover;
  final HeadlessHost _headlessHost;
  late final _headless = RaccoonControl(_headlessHost);
  RaccoonControlClient? _simulator;

  /// The headless runs, for tests and for stopping them.
  HeadlessHost get headless => _headlessHost;

  /// Calls [method]; the result as JSON, with `host` saying where it ran.
  /// Throws a [RaccoonControlError] when it fails.
  Future<Map<String, Object?>> call(
    String method,
    Map<String, Object?> params,
  ) async {
    final args = {...params};
    if (method == 'run') {
      if (args['project'] case final String project when project.isNotEmpty) {
        args['project'] = _absolute(project);
      }
    }
    if (choice == HostChoice.headless) return _headless.call(method, args);
    if (method == 'list_devices') return _listDevices(args);
    // A call at an app this process runs goes to it, simulator or not.
    if (method != 'run' && _headlessTargets(args)) {
      return _headless.call(method, args);
    }
    return _onSimulator(method, args);
  }

  /// Stops the headless runs and lets go of the simulator.
  Future<void> close() async {
    _simulator?.close();
    _simulator = null;
    await _headlessHost.stopAll();
  }

  Future<Map<String, Object?>> _onSimulator(
    String method,
    Map<String, Object?> args,
  ) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final simulator = await _simulatorClient();
      if (simulator == null) break;
      try {
        return await simulator.call(method, args);
      } on RaccoonControlError {
        rethrow;
      } on Object {
        // Gone, or a new one since: look again.
        simulator.close();
        _simulator = null;
      }
    }
    if (choice == HostChoice.simulator) {
      throw const RaccoonControlError(
        RaccoonControlError.failed,
        'no Raccoon Simulator is open on this machine; open one, or start '
        'raccoon_mcp without --host simulator to run headless',
      );
    }
    return _headless.call(method, args);
  }

  Future<Map<String, Object?>> _listDevices(Map<String, Object?> args) async {
    final ours = _headlessHost.apps();
    if (choice == HostChoice.simulator || ours.isEmpty) {
      return _onSimulator('list_devices', args);
    }
    final headless = await _headless.call('list_devices', args);
    final simulator = await _simulatorClient();
    if (simulator == null) return headless;
    final Map<String, Object?> shown;
    try {
      shown = await simulator.call('list_devices', args);
    } on Object {
      return headless;
    }
    // The simulator's devices, with this process's headless apps added to
    // each, each app saying where it runs.
    final extra = <String, List<Object?>>{};
    for (final device in headless['devices'] as List) {
      final map = device as Map;
      extra[map['id'] as String] = [
        for (final app in map['apps'] as List)
          {...(app as Map), 'host': 'headless'},
      ];
    }
    return {
      ...shown,
      'devices': [
        for (final device in shown['devices'] as List)
          {
            ...(device as Map),
            'apps': [
              for (final app in device['apps'] as List)
                {...(app as Map), 'host': 'simulator'},
              ...?extra[device['id']],
            ],
          },
      ],
    };
  }

  bool _headlessTargets(Map<String, Object?> args) {
    if (_headlessHost.apps().isEmpty) return false;
    try {
      RaccoonControl(_headlessHost).target(args);
      return true;
    } on RaccoonControlError {
      return false;
    }
  }

  Future<RaccoonControlClient?> _simulatorClient() async {
    if (_simulator case final simulator?) return simulator;
    final found =
        await (_discover?.call() ??
            RaccoonControlClient.discover(environment: _environment));
    return _simulator = found;
  }

  String _absolute(String project) {
    final home = _environment['HOME'] ?? _environment['USERPROFILE'];
    final expanded = switch (project) {
      '~' when home != null => home,
      _ when project.startsWith('~/') && home != null => p.join(
        home,
        project.substring(2),
      ),
      _ => project,
    };
    return p.normalize(p.absolute(_workingDirectory, expanded));
  }
}

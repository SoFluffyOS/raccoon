import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/src/runner_endpoint.dart';

/// Finds runners by the sockets they listen on and watches for new ones. The
/// device helper puts each app's socket at `<runtime dir>/raccoon/<app>.sock`.
final class RunnerDiscovery {
  const RunnerDiscovery(this.directory, {this.pollInterval});

  /// The host's socket directory, next to [RunnerEndpoint.forHost]'s default
  /// socket: `$XDG_RUNTIME_DIR/raccoon` on Linux, `<temporary
  /// directory>/raccoon` elsewhere.
  factory RunnerDiscovery.forHost({
    required String operatingSystem,
    required Map<String, String> environment,
    required String temporaryDirectory,
  }) {
    final endpoint = RunnerEndpoint.forHost(
      operatingSystem: operatingSystem,
      environment: environment,
      temporaryDirectory: temporaryDirectory,
    );
    return switch (endpoint) {
      UnixSocketEndpoint(:final path) => RunnerDiscovery(
        p.dirname(path),
        pollInterval: pollIntervalFor(operatingSystem),
      ),
      LoopbackTcpEndpoint() => RunnerDiscovery(
        p.join(temporaryDirectory, 'raccoon'),
      ),
    };
  }

  /// Linux hears about sockets from inotify. macOS reports no file system
  /// event for a socket's creation or removal, so its directory is polled.
  static Duration? pollIntervalFor(String operatingSystem) =>
      switch (operatingSystem) {
        'macos' => const Duration(milliseconds: 500),
        _ => null,
      };

  static const String socketSuffix = '.sock';

  final String directory;

  /// How often to list the directory instead of watching it, see
  /// [pollIntervalFor].
  final Duration? pollInterval;

  /// The app name a socket stands for: its file name without the suffix.
  static String appNameOf(UnixSocketEndpoint endpoint) =>
      p.basenameWithoutExtension(endpoint.path);

  /// The project behind an app name, without its instance: `wonders` for
  /// `wonders@2`, the second run of the same project (see the device
  /// helper's `--instance`).
  static String projectOf(String appName) => appName.split('@').first;

  /// Which run of its project an app name is: 1 for `wonders`, 2 for
  /// `wonders@2`.
  static int instanceOf(String appName) => switch (appName.split('@')) {
    [_, final instance] => int.tryParse(instance) ?? 1,
    _ => 1,
  };

  /// Every runner socket present right now, sorted by path.
  List<UnixSocketEndpoint> list() {
    final dir = Directory(directory);
    if (!dir.existsSync()) return const [];
    final found = <UnixSocketEndpoint>[
      for (final entity in dir.listSync())
        if (entity.path.endsWith(socketSuffix) &&
            FileSystemEntity.typeSync(entity.path) ==
                FileSystemEntityType.unixDomainSock)
          UnixSocketEndpoint(entity.path),
    ];
    found.sort((a, b) => a.path.compareTo(b.path));
    return found;
  }

  /// The current runners, then the list again whenever one appears, goes,
  /// or is replaced under the same path, as every `flutter run` of the same
  /// app does.
  Stream<List<UnixSocketEndpoint>> watch() {
    final dir = Directory(directory);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    StreamSubscription<FileSystemEvent>? events;
    Timer? timer;
    List<_Seen>? last;
    late final StreamController<List<UnixSocketEndpoint>> controller;
    void emitIfChanged() {
      final found = list();
      final seen = [
        for (final endpoint in found)
          (path: endpoint.path, changed: _changedAt(endpoint.path)),
      ];
      if (last case final previous? when _sameRunners(previous, seen)) return;
      last = seen;
      controller.add(found);
    }

    controller = StreamController(
      onListen: () {
        emitIfChanged();
        switch (pollInterval) {
          case final interval?:
            timer = Timer.periodic(interval, (_) => emitIfChanged());
          case null:
            events = dir
                .watch(
                  events:
                      FileSystemEvent.create |
                      FileSystemEvent.delete |
                      FileSystemEvent.move,
                )
                .listen(
                  (_) => emitIfChanged(),
                  onError: controller.addError,
                  onDone: controller.close,
                );
        }
      },
      onCancel: () {
        timer?.cancel();
        return events?.cancel();
      },
    );
    return controller.stream;
  }

  /// When the socket was created, so a replacement under the same path
  /// counts as a change; 0 once it is gone.
  static int _changedAt(String path) {
    final stat = FileStat.statSync(path);
    return switch (stat.type) {
      FileSystemEntityType.notFound => 0,
      _ => stat.changed.microsecondsSinceEpoch,
    };
  }

  static bool _sameRunners(List<_Seen> a, List<_Seen> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].path != b[i].path || a[i].changed != b[i].changed) return false;
    }
    return true;
  }
}

typedef _Seen = ({String path, int changed});

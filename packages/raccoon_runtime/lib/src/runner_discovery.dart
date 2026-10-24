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
    final paths = switch (operatingSystem) {
      'windows' => p.windows,
      _ => p.posix,
    };
    return switch (endpoint) {
      UnixSocketEndpoint(:final path) => RunnerDiscovery(
        paths.dirname(path),
        pollInterval: pollIntervalFor(operatingSystem),
      ),
    };
  }

  /// Linux hears about sockets from inotify and Windows from its directory
  /// changes. macOS reports no file system event for a socket's creation or
  /// removal, so its directory is polled.
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
  static String appNameOf(UnixSocketEndpoint endpoint) {
    final base = p.basenameWithoutExtension(endpoint.path);
    // A key too long for a socket path runs as <start>~<checksum>, the key
    // in a .name file beside the socket (#118).
    if (!base.contains('~')) return base;
    try {
      final named = File(p.join(p.dirname(endpoint.path), '$base.name'));
      final name = named.readAsStringSync().trim();
      if (name.isNotEmpty) return name;
    } on FileSystemException {
      // No .name file: the socket's own name it is.
    }
    return base;
  }

  /// The project behind an app name, without its instance: `wonders` for
  /// `wonders@2`, the second run of the same project (see the device
  /// helper's `--instance`).
  static String projectOf(String appName) => appName.split('@').first;

  /// Which run of its project an app name is: 1 for `wonders`, 2 for
  /// `wonders@2`.
  static String instanceOf(String appName) => switch (appName.split('@')) {
    [_, final instance] when instance.isNotEmpty => instance,
    _ => '1',
  };

  /// Every runner socket present right now, sorted by path.
  List<UnixSocketEndpoint> list() {
    final dir = Directory(directory);
    if (!dir.existsSync()) return const [];
    final List<FileSystemEntity> entities;
    try {
      entities = dir.listSync();
    } on FileSystemException {
      // Removed since it was checked: no runners there.
      return const [];
    }
    final found = <UnixSocketEndpoint>[
      for (final entity in entities)
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
          (path: endpoint.path, stamp: _stampOf(endpoint.path)),
      ];
      if (last case final previous? when _sameRunners(previous, seen)) return;
      last = seen;
      controller.add(found);
    }

    var cancelled = false;
    // The watch ends when the directory goes, as a temp cleaner can take
    // it: it is made again and watched again, so runners started later
    // still show (#134).
    void startWatching() {
      try {
        if (!dir.existsSync()) dir.createSync(recursive: true);
      } on FileSystemException catch (error, stackTrace) {
        controller
          ..addError(error, stackTrace)
          ..close();
        return;
      }
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
            onDone: () {
              if (cancelled) return;
              emitIfChanged();
              startWatching();
            },
          );
    }

    controller = StreamController(
      onListen: () {
        emitIfChanged();
        switch (pollInterval) {
          case final interval?:
            timer = Timer.periodic(interval, (_) => emitIfChanged());
          case null:
            startWatching();
        }
      },
      onCancel: () {
        cancelled = true;
        timer?.cancel();
        return events?.cancel();
      },
    );
    return controller.stream;
  }

  /// When the socket was created, so a replacement under the same path
  /// counts as a change; null once it is gone. Windows reports its creation
  /// time as changed, and gives a file made again under a name just freed
  /// the old one's (file system tunnelling), so the modification time
  /// counts too.
  static (int, int)? _stampOf(String path) {
    final stat = FileStat.statSync(path);
    return switch (stat.type) {
      FileSystemEntityType.notFound => null,
      _ => (
        stat.changed.microsecondsSinceEpoch,
        stat.modified.microsecondsSinceEpoch,
      ),
    };
  }

  static bool _sameRunners(List<_Seen> a, List<_Seen> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].path != b[i].path || a[i].stamp != b[i].stamp) return false;
    }
    return true;
  }
}

typedef _Seen = ({String path, (int, int)? stamp});

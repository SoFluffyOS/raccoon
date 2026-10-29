import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/src/runner_endpoint.dart';

/// Finds runners by the sockets they listen on and watches for new ones. The
/// device helper puts each app's socket at `<runtime dir>/raccoon/<app>.sock`.
final class RunnerDiscovery {
  const RunnerDiscovery(this.directory, {this.pollInterval, this.watcher});

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

  /// The extension of a runner's socket file.
  static const String socketSuffix = '.sock';

  /// How often a watch that could not be set up polls instead.
  static const fallbackPollInterval = Duration(milliseconds: 500);

  /// The directory the runners' sockets sit in.
  final String directory;

  /// How often to list the directory instead of watching it, see
  /// [pollIntervalFor].
  final Duration? pollInterval;

  /// Watches a directory; the platform's watch unless a test stands in.
  final Stream<FileSystemEvent> Function(Directory directory)? watcher;

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

  /// Every runner socket present right now, sorted by path; none in a
  /// directory that may be another user's (see [isOwn]).
  List<UnixSocketEndpoint> list() => switch (isOwn) {
    true => [for (final seen in _scan()) UnixSocketEndpoint(seen.path)],
    false => const [],
  };

  /// Whether the runners in [directory] can only be this user's. In a
  /// folder others may write to, as `/tmp` is where Linux has no
  /// `XDG_RUNTIME_DIR`, another user could have made the directory first,
  /// or left a link there, with sockets of theirs that would be shown this
  /// user's taps and keys. There it counts only when it is a directory this
  /// user owns, which nobody else can hand over, and nobody else may write
  /// to. Windows says nothing of the kind, so there it counts.
  bool get isOwn {
    if (Platform.isWindows) return true;
    final parent = FileStat.statSync(p.dirname(directory));
    if (parent.type == FileSystemEntityType.notFound ||
        parent.mode & _groupOrOthersWrite == 0) {
      return true;
    }
    final own = FileStat.statSync(directory);
    if (own.type == FileSystemEntityType.notFound) return true;
    if (own.mode & _groupOrOthersWrite != 0) return false;
    // Asked of `stat` once while the directory stays as it was: any change
    // to it, its mode or its contents changes its ctime.
    if (_owned[directory] == own.changed) return true;
    final owned = _ownedByUser(directory);
    if (owned) {
      _owned[directory] = own.changed;
    } else {
      _owned.remove(directory);
    }
    return owned;
  }

  static const _groupOrOthersWrite = 0x12;

  static final _owned = <String, DateTime>{};

  static final String? _uid = _run('id', ['-u']);

  /// Whether [path] itself, not what a link there points to, is a
  /// directory this process's user owns.
  static bool _ownedByUser(String path) {
    final said = switch (Platform.isMacOS) {
      true => _run('stat', ['-f', '%u %HT', path]),
      false => _run('stat', ['-c', '%u %F', path]),
    };
    if (said == null || _uid == null) return false;
    final [owner, ...kind] = said.split(' ');
    return owner == _uid && kind.join(' ').toLowerCase() == 'directory';
  }

  static String? _run(String executable, List<String> arguments) {
    try {
      final result = Process.runSync(executable, arguments);
      if (result.exitCode != 0) return null;
      return '${result.stdout}'.trim();
    } on ProcessException {
      return null;
    }
  }

  /// Makes [dir] for this user alone, as the device helper does.
  static void _make(Directory dir) {
    dir.createSync(recursive: true);
    if (!Platform.isWindows) Process.runSync('chmod', ['700', dir.path]);
  }

  /// The sockets with their stamps (see [_stampFrom]), one stat each: a
  /// watch that polls does this twice a second.
  List<_Seen> _scan() {
    final List<FileSystemEntity> entities;
    try {
      entities = Directory(directory).listSync();
    } on FileSystemException {
      // Not there (yet, or any more): no runners there.
      return const [];
    }
    final found = <_Seen>[];
    for (final entity in entities) {
      if (!entity.path.endsWith(socketSuffix)) continue;
      final stat = FileStat.statSync(entity.path);
      if (stat.type != FileSystemEntityType.unixDomainSock) continue;
      found.add((path: entity.path, stamp: _stampFrom(stat)));
    }
    found.sort((a, b) => a.path.compareTo(b.path));
    return found;
  }

  /// The current runners, then the list again whenever one appears, goes,
  /// or is replaced under the same path, as every `flutter run` of the same
  /// app does.
  Stream<List<UnixSocketEndpoint>> watch() {
    final dir = Directory(directory);
    try {
      if (!dir.existsSync()) _make(dir);
    } on FileSystemException catch (error, stackTrace) {
      // On the stream, as every other failure of the watch.
      return Stream.error(error, stackTrace);
    }
    StreamSubscription<FileSystemEvent>? events;
    Timer? timer;
    List<_Seen>? last;
    late final StreamController<List<UnixSocketEndpoint>> controller;
    var refused = false;
    void emitIfChanged() {
      if (controller.isClosed) return;
      final own = isOwn;
      if (!own && !refused) {
        controller.addError(
          FileSystemException(
            'not a directory of this user\'s alone, so its runners could be '
            'another user\'s: set XDG_RUNTIME_DIR, or make it yours (chmod 700)',
            directory,
          ),
        );
      }
      refused = !own;
      final seen = switch (own) {
        true => _scan(),
        false => const <_Seen>[],
      };
      if (last case final previous? when _sameRunners(previous, seen)) return;
      last = seen;
      controller.add([for (final one in seen) UnixSocketEndpoint(one.path)]);
    }

    var cancelled = false;
    // A watch that ends with its directory gone, as a temp cleaner can take
    // it (on Windows it fails instead), makes it again and watches again,
    // so runners started later still show (#134). One that ends with the
    // directory still there could not be set up, as when Linux runs out of
    // inotify watches: polling takes over, rather than a new watch failing
    // the same way at once, for good (#137).
    void startWatching() {
      try {
        if (!dir.existsSync()) _make(dir);
      } on FileSystemException catch (error, stackTrace) {
        controller
          ..addError(error, stackTrace)
          ..close();
        return;
      }
      late final StreamSubscription<FileSystemEvent> watching;
      void again() {
        if (cancelled || !identical(events, watching)) return;
        unawaited(watching.cancel());
        events = null;
        if (dir.existsSync()) {
          emitIfChanged();
          timer ??= Timer.periodic(
            fallbackPollInterval,
            (_) => emitIfChanged(),
          );
          return;
        }
        startWatching();
        emitIfChanged();
      }

      final watch =
          watcher?.call(dir) ??
          dir.watch(
            events:
                FileSystemEvent.create |
                FileSystemEvent.delete |
                FileSystemEvent.move,
          );
      watching = watch.listen(
        (_) => emitIfChanged(),
        onError: (Object error, StackTrace stackTrace) {
          if (!dir.existsSync()) return again();
          controller.addError(error, stackTrace);
        },
        onDone: again,
      );
      events = watching;
    }

    controller = StreamController(
      onListen: () {
        switch (pollInterval) {
          case final interval?:
            timer = Timer.periodic(interval, (_) => emitIfChanged());
          case null:
            startWatching();
        }
        // Listed once the watch is up: Linux and Windows tell only of what
        // changes after, so a runner that bound in between was missed until
        // something else changed (#230).
        emitIfChanged();
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
  static (int, int)? _stampFrom(FileStat stat) {
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

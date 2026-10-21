import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/src/runner_endpoint.dart';

/// Finds runners by the sockets they listen on and watches for new ones. The
/// device helper puts each app's socket at `<runtime dir>/raccoon/<app>.sock`.
final class RunnerDiscovery {
  const RunnerDiscovery(this.directory);

  /// The host's socket directory: `$XDG_RUNTIME_DIR/raccoon`, else
  /// `<temporary directory>/raccoon`.
  factory RunnerDiscovery.forHost(
    Map<String, String> environment,
    String temporaryDirectory,
  ) {
    final endpoint = RunnerEndpoint.forHost(
      operatingSystem: 'linux',
      environment: environment,
      temporaryDirectory: temporaryDirectory,
    );
    return switch (endpoint) {
      UnixSocketEndpoint(:final path) => RunnerDiscovery(p.dirname(path)),
      LoopbackTcpEndpoint() => RunnerDiscovery(
        p.join(temporaryDirectory, 'raccoon'),
      ),
    };
  }

  static const String socketSuffix = '.sock';

  final String directory;

  /// The app name a socket stands for: its file name without the suffix.
  static String appNameOf(UnixSocketEndpoint endpoint) =>
      p.basenameWithoutExtension(endpoint.path);

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

  /// The current runners, then the list again whenever one appears or goes.
  Stream<List<UnixSocketEndpoint>> watch() async* {
    final dir = Directory(directory);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    yield list();
    await for (final _ in dir.watch(
      events:
          FileSystemEvent.create |
          FileSystemEvent.delete |
          FileSystemEvent.move,
    )) {
      yield list();
    }
  }
}

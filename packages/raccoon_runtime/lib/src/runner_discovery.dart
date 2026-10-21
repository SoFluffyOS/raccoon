import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/src/runner_endpoint.dart';

/// Finds runners by the sockets they listen on and watches for new ones. The
/// device helper puts each app's socket at `<runtime dir>/raccoon/<app>.sock`.
final class RunnerDiscovery {
  const RunnerDiscovery(this.directory);

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
  Stream<List<UnixSocketEndpoint>> watch() {
    final dir = Directory(directory);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    StreamSubscription<FileSystemEvent>? events;
    late final StreamController<List<UnixSocketEndpoint>> controller;
    controller = StreamController(
      onListen: () {
        controller.add(list());
        events = dir
            .watch(
              events:
                  FileSystemEvent.create |
                  FileSystemEvent.delete |
                  FileSystemEvent.move,
            )
            .listen(
              (_) => controller.add(list()),
              onError: controller.addError,
              onDone: controller.close,
            );
      },
      onCancel: () => events?.cancel(),
    );
    return controller.stream;
  }
}

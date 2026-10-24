import 'package:path/path.dart' as p;

/// Where the runner listens on this host.
sealed class RunnerEndpoint {
  const RunnerEndpoint();

  /// The default endpoint for [operatingSystem]: a Unix socket on every
  /// host, Windows included, whose AF_UNIX sockets dart:io and the runner
  /// both speak. It sits in the XDG runtime directory on Linux, in the
  /// temporary directory elsewhere.
  factory RunnerEndpoint.forHost({
    required String operatingSystem,
    required Map<String, String> environment,
    required String temporaryDirectory,
  }) {
    return switch (operatingSystem) {
      'linux' => UnixSocketEndpoint(
        _socketIn(p.posix, _runtimeDirectory(environment, temporaryDirectory)),
      ),
      'windows' => UnixSocketEndpoint(_socketIn(p.windows, temporaryDirectory)),
      _ => UnixSocketEndpoint(_socketIn(p.posix, temporaryDirectory)),
    };
  }

  /// The value handed to hosted apps as `RACCOON_ENDPOINT`.
  String get uri;

  static String _socketIn(p.Context context, String directory) =>
      context.join(directory, 'raccoon', 'runner.sock');

  static String _runtimeDirectory(
    Map<String, String> environment,
    String fallback,
  ) {
    if (environment['XDG_RUNTIME_DIR'] case final directory?
        when directory.isNotEmpty) {
      return directory;
    }
    return fallback;
  }
}

/// A Unix domain socket: a socket file on every host.
final class UnixSocketEndpoint extends RunnerEndpoint {
  const UnixSocketEndpoint(this.path);

  /// The socket file's path.
  final String path;

  @override
  String get uri => 'unix:$path';
}

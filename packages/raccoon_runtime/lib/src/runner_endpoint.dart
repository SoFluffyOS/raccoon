import 'package:path/path.dart' as p;

/// Where the runner listens on this host.
sealed class RunnerEndpoint {
  const RunnerEndpoint();

  /// The default endpoint for [operatingSystem]: a Unix socket on Linux and
  /// macOS, loopback TCP on Windows, where dart:io has no Unix sockets.
  factory RunnerEndpoint.forHost({
    required String operatingSystem,
    required Map<String, String> environment,
    required String temporaryDirectory,
  }) {
    return switch (operatingSystem) {
      'windows' => LoopbackTcpEndpoint(_portFrom(environment)),
      'linux' => UnixSocketEndpoint(
          _socketIn(_runtimeDirectory(environment, temporaryDirectory)),
        ),
      _ => UnixSocketEndpoint(_socketIn(temporaryDirectory)),
    };
  }

  /// The value handed to hosted apps as `RACCOON_ENDPOINT`.
  String get uri;

  static String _socketIn(String directory) =>
      p.posix.join(directory, 'raccoon', 'runner.sock');

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

  static int _portFrom(Map<String, String> environment) {
    final port = int.tryParse(environment['RACCOON_PORT'] ?? '');
    return port ?? LoopbackTcpEndpoint.defaultPort;
  }
}

/// A Unix domain socket, on Linux and macOS.
final class UnixSocketEndpoint extends RunnerEndpoint {
  const UnixSocketEndpoint(this.path);

  final String path;

  @override
  String get uri => 'unix:$path';
}

/// A loopback TCP port, on Windows.
final class LoopbackTcpEndpoint extends RunnerEndpoint {
  const LoopbackTcpEndpoint(this.port);

  static const int defaultPort = 41919;

  final int port;

  @override
  String get uri => 'tcp:127.0.0.1:$port';
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/src/control/control_host.dart';
import 'package:raccoon_runtime/src/control/control_server.dart';
import 'package:raccoon_runtime/src/control/raccoon_control.dart';
import 'package:raccoon_runtime/src/runner_discovery.dart';

/// Calls a host's control endpoint ([RaccoonControlServer]), as an agent's
/// MCP server does.
final class RaccoonControlClient implements RaccoonControlCalls {
  RaccoonControlClient(this.uri, this.token, {this.host = '', this.pid})
    : _http = HttpClient()..idleTimeout = const Duration(seconds: 30);

  /// The wire's version, in each host's file.
  static const version = 1;

  /// The endpoint: `http://127.0.0.1:<port>`.
  final Uri uri;

  final String token;

  /// What the host is, from its file: `simulator`.
  final String host;

  /// The host's process id, from its file.
  final int? pid;

  final HttpClient _http;

  /// The live endpoint of a host on this machine, the newest first, or
  /// null when none answers within [timeout]. `RACCOON_CONTROL` in
  /// [environment] names a host's file to take instead of looking.
  static Future<RaccoonControlClient?> discover({
    Map<String, String>? environment,
    String? directory,
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final env = environment ?? Platform.environment;
    final named = env['RACCOON_CONTROL'];
    final files = switch (named) {
      final path? when path.isNotEmpty => [File(path)],
      _ => _filesIn(
        directory ?? RaccoonControlServer.directoryFor(environment: env),
      ),
    };
    for (final file in files) {
      final client = fromFile(file);
      if (client == null) continue;
      try {
        await client.hello().timeout(timeout);
        return client;
      } on Object {
        client.close();
      }
    }
    return null;
  }

  /// The client a host's file describes, or null for one that does not
  /// read as one.
  static RaccoonControlClient? fromFile(File file) {
    try {
      final json = jsonDecode(file.readAsStringSync());
      if (json case {
        'version': version,
        'url': final String url,
        'token': final String token,
      }) {
        final uri = Uri.parse(url);
        // Loopback only, whatever a file says.
        if (uri.host != '127.0.0.1' && uri.host != 'localhost') return null;
        return RaccoonControlClient(
          uri,
          token,
          host: json['host'] as String? ?? '',
          pid: json['pid'] as int?,
        );
      }
    } on Object {
      return null;
    }
    return null;
  }

  /// The hosts' files in [directory], the newest first; none in a
  /// directory another user could have made.
  static List<File> _filesIn(String directory) {
    final folder = Directory(directory);
    if (!folder.existsSync()) return const [];
    if (!RunnerDiscovery(directory).isOwn) return const [];
    final files = [
      for (final entity in folder.listSync())
        if (entity is File && p.extension(entity.path) == '.json') entity,
    ];
    final modified = {for (final file in files) file: file.lastModifiedSync()};
    files.sort((a, b) => modified[b]!.compareTo(modified[a]!));
    return files;
  }

  /// The host's name, version and methods.
  Future<Map<String, Object?>> hello() => _request('GET', '/v1/hello');

  @override
  Future<Map<String, Object?>> call(
    String method,
    Map<String, Object?> params,
  ) => _request('POST', '/v1/call', {'method': method, 'params': params});

  Future<Map<String, Object?>> _request(
    String verb,
    String path, [
    Map<String, Object?>? body,
  ]) async {
    final request = await _http.openUrl(verb, uri.resolve(path));
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
      ..contentType = ContentType.json;
    if (body != null) request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw RaccoonControlError(
        RaccoonControlError.failed,
        'the host answered ${response.statusCode} without JSON',
      );
    }
    return switch (json) {
      {'result': final Map result} => result.cast<String, Object?>(),
      {'error': {'code': final String code, 'message': final String message}} =>
        throw RaccoonControlError(code, message),
      _ =>
        throw RaccoonControlError(
          RaccoonControlError.failed,
          'the host answered ${response.statusCode}: $text',
        ),
    };
  }

  void close() => _http.close(force: true);
}

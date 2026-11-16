import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/src/control/control_client.dart';
import 'package:raccoon_runtime/src/control/control_host.dart';
import 'package:raccoon_runtime/src/control/raccoon_control.dart';
import 'package:raccoon_runtime/src/runner_discovery.dart';

/// A host's control endpoint: [RaccoonControl]'s calls over HTTP on the
/// loopback interface, for this user's agents.
///
/// It listens on 127.0.0.1 at a port of the system's choosing, and answers
/// only a request that carries its token (`Authorization: Bearer <token>`)
/// and no browser `Origin`. The port and the token are in a file only this
/// user can read, `<runner socket directory>/control/<host>-<pid>.json`
/// (`$XDG_RUNTIME_DIR/raccoon/control` on Linux), where
/// [RaccoonControlClient.discover] finds it; it goes with [close].
///
/// `POST /v1/call` with `{"method": "tap", "params": {...}}` answers
/// `{"result": {...}}`, or `{"error": {"code": ..., "message": ...}}`;
/// `GET /v1/hello` names the host and its methods.
final class RaccoonControlServer {
  RaccoonControlServer._(
    this._server,
    this.control,
    this.token,
    this.file,
    this.kind,
  );

  /// Starts serving [control] and writes its file into [directory], or
  /// [directoryFor] this host's when null.
  static Future<RaccoonControlServer> start(
    RaccoonControlCalls control, {
    required String kind,
    String? directory,
    String? token,
  }) async {
    final folder = directory ?? directoryFor();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final secret = token ?? newToken();
    final file = File(p.join(folder, '$kind-$pid.json'));
    final serving = RaccoonControlServer._(server, control, secret, file, kind);
    try {
      await _writePrivately(file, {
        'version': RaccoonControlClient.version,
        'host': kind,
        'pid': pid,
        'url': serving.uri.toString(),
        'token': secret,
      });
    } on Object {
      await server.close(force: true);
      rethrow;
    }
    serving._subscription = server.listen(
      (request) => unawaited(serving._handle(request)),
    );
    return serving;
  }

  /// Where hosts put their files on this machine, beside the runners'
  /// sockets: `$XDG_RUNTIME_DIR/raccoon/control` on Linux, the temporary
  /// directory's `raccoon/control` elsewhere. This user's alone.
  static String directoryFor({Map<String, String>? environment}) {
    final discovery = RunnerDiscovery.forHost(
      operatingSystem: Platform.operatingSystem,
      environment: environment ?? Platform.environment,
      temporaryDirectory: Directory.systemTemp.path,
    );
    return p.join(discovery.directory, 'control');
  }

  /// 32 random bytes, URL-safe base64.
  static String newToken() {
    final random = Random.secure();
    return base64Url
        .encode(List<int>.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  final HttpServer _server;

  /// What the calls go to.
  final RaccoonControlCalls control;

  /// What a request has to carry.
  final String token;

  /// The file that tells clients the port and the token.
  final File file;

  /// What the host is: `simulator`.
  final String kind;

  StreamSubscription<HttpRequest>? _subscription;

  /// `http://127.0.0.1:<port>`.
  Uri get uri => Uri(scheme: 'http', host: '127.0.0.1', port: _server.port);

  /// Stops serving and removes the file.
  Future<void> close() async {
    await _subscription?.cancel();
    await _server.close(force: true);
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Gone already.
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (!request.connectionInfo!.remoteAddress.isLoopback ||
          request.headers.value('origin') != null) {
        return await _send(response, HttpStatus.forbidden, {
          'error':
              const RaccoonControlError(
                RaccoonControlError.unauthorized,
                'only local tools, not browsers',
              ).toJson(),
        });
      }
      if (!_authorized(request.headers.value('authorization'))) {
        return await _send(response, HttpStatus.unauthorized, {
          'error':
              const RaccoonControlError(
                RaccoonControlError.unauthorized,
                'no token, or not this endpoint\'s',
              ).toJson(),
        });
      }
      switch ((request.method, request.uri.path)) {
        case ('GET', '/v1/hello'):
          return await _send(response, HttpStatus.ok, {
            'result': {
              'host': kind,
              'version': RaccoonControlClient.version,
              'pid': pid,
              'methods': RaccoonControl.methods,
            },
          });
        case ('POST', '/v1/call'):
          final body = await _readBody(request);
          final (method, params) = switch (body) {
            {'method': final String method, 'params': final Map params} => (
              method,
              params.cast<String, Object?>(),
            ),
            {'method': final String method} => (method, <String, Object?>{}),
            _ =>
              throw const RaccoonControlError(
                RaccoonControlError.badParams,
                'the body is {"method": ..., "params": {...}}',
              ),
          };
          final result = await control.call(method, params);
          return await _send(response, HttpStatus.ok, {'result': result});
        default:
          return await _send(response, HttpStatus.notFound, {
            'error':
                const RaccoonControlError(
                  RaccoonControlError.unknownMethod,
                  'POST /v1/call or GET /v1/hello',
                ).toJson(),
          });
      }
    } on RaccoonControlError catch (error) {
      return await _send(
        response,
        switch (error.code) {
          RaccoonControlError.badParams ||
          RaccoonControlError.unknownMethod => HttpStatus.badRequest,
          RaccoonControlError.noApp ||
          RaccoonControlError.ambiguous => HttpStatus.notFound,
          _ => HttpStatus.unprocessableEntity,
        },
        {'error': error.toJson()},
      );
    } on Object catch (error) {
      return await _send(response, HttpStatus.internalServerError, {
        'error':
            RaccoonControlError(RaccoonControlError.failed, '$error').toJson(),
      });
    }
  }

  bool _authorized(String? header) {
    const scheme = 'Bearer ';
    if (header == null || !header.startsWith(scheme)) return false;
    final given = utf8.encode(header.substring(scheme.length).trim());
    final wanted = utf8.encode(token);
    // In constant time: how far a guess matched says nothing.
    var differs = given.length ^ wanted.length;
    for (var i = 0; i < wanted.length; i++) {
      differs |= wanted[i] ^ (i < given.length ? given[i] : 0);
    }
    return differs == 0;
  }

  /// How big a call's body may be: a text to type, not a file.
  static const maxBody = 1 << 20;

  static Future<Object?> _readBody(HttpRequest request) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
      if (bytes.length > maxBody) {
        throw const RaccoonControlError(
          RaccoonControlError.badParams,
          'the body is over 1 MB',
        );
      }
    }
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const RaccoonControlError(
        RaccoonControlError.badParams,
        'the body is not JSON',
      );
    }
  }

  static Future<void> _send(
    HttpResponse response,
    int status,
    Map<String, Object?> body,
  ) async {
    try {
      response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await response.close();
    } on Object {
      // The caller hung up.
    }
  }

  /// Writes [json] to [file], readable by this user alone, in a directory
  /// only this user can enter.
  static Future<void> _writePrivately(
    File file,
    Map<String, Object?> json,
  ) async {
    final folder = file.parent;
    if (!folder.existsSync()) folder.createSync(recursive: true);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['700', folder.parent.path, folder.path]);
    }
    final temporary = File('${file.path}.tmp');
    temporary.writeAsStringSync('');
    if (!Platform.isWindows) {
      await Process.run('chmod', ['600', temporary.path]);
    }
    temporary.writeAsStringSync(jsonEncode(json), flush: true);
    temporary.renameSync(file.path);
  }
}

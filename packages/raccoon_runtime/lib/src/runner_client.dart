import 'dart:async';
import 'dart:io';

import 'package:raccoon/raccoon.dart';
import 'package:raccoon_runtime/src/message_framing.dart';
import 'package:raccoon_runtime/src/runner_connection.dart';
import 'package:raccoon_runtime/src/runner_endpoint.dart';

/// A connection to one runner: frames and logs in, resize and input out.
final class RunnerClient implements RunnerConnection {
  RunnerClient._(this._socket) {
    _subscription = _socket.listen(
      _onBytes,
      onDone: _onDone,
      onError: _onError,
    );
    send(
      ClientMessage(
        hello: ClientHello(
          protocolVersion: RaccoonProtocol.version,
          clientName: 'raccoon_runtime',
        ),
      ),
    );
  }

  /// Connects to the runner at [endpoint] and sends the client hello.
  static Future<RunnerClient> connect(RunnerEndpoint endpoint) async {
    final socket = switch (endpoint) {
      UnixSocketEndpoint(:final path) => await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      ),
      LoopbackTcpEndpoint(:final port) => await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
      ),
    };
    return RunnerClient._(socket);
  }

  final Socket _socket;
  final _unframer = MessageUnframer();
  final _messages = StreamController<RunnerMessage>.broadcast();
  final _hello = Completer<RunnerHello>();
  final _closed = Completer<void>();
  late final StreamSubscription<List<int>> _subscription;
  Frame? _latestFrame;
  String? _vmServiceUri;

  /// Every message the runner sends, after the connection was made.
  Stream<RunnerMessage> get messages => _messages.stream;

  /// The runner's hello, with its protocol version.
  Future<RunnerHello> get hello => _hello.future;

  @override
  Stream<Frame> get frames async* {
    if (_latestFrame case final frame?) yield frame;
    yield* messages.where((m) => m.hasFrame()).map((m) => m.frame);
  }

  /// The latest frame the runner sent, if any.
  Frame? get latestFrame => _latestFrame;

  /// The Dart VM service URI once the runner reported it.
  String? get vmServiceUri => _vmServiceUri;

  /// Completes when the runner closed the connection.
  Future<void> get closed => _closed.future;

  @override
  void resize(int width, int height, double pixelRatio) => send(
    ClientMessage(
      resize: Resize(width: width, height: height, pixelRatio: pixelRatio),
    ),
  );

  @override
  void sendPointer(PointerEvent event) => send(ClientMessage(pointer: event));

  @override
  void sendKey(KeyEvent event) => send(ClientMessage(key: event));

  /// Asks the runner to stop.
  void shutdown() => send(ClientMessage(shutdown: Shutdown()));

  void send(ClientMessage message) {
    if (_closed.isCompleted) return;
    _socket.add(MessageFraming.frame(message.writeToBuffer()));
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _socket.close();
    _finish();
  }

  void _onBytes(List<int> chunk) {
    for (final payload in _unframer.add(chunk)) {
      final message = RunnerMessage.fromBuffer(payload);
      if (message.hasHello() && !_hello.isCompleted) {
        _hello.complete(message.hello);
      }
      if (message.hasFrame()) _latestFrame = message.frame;
      if (message.hasVmService()) _vmServiceUri = message.vmService.uri;
      _messages.add(message);
    }
  }

  void _onDone() => _finish();

  void _onError(Object error, StackTrace stackTrace) {
    _messages.addError(error, stackTrace);
    _finish();
  }

  void _finish() {
    if (_closed.isCompleted) return;
    _closed.complete();
    unawaited(_messages.close());
  }
}

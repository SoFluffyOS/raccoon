import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:raccoon/raccoon.dart';
import 'package:raccoon_runtime/src/message_framing.dart';
import 'package:raccoon_runtime/src/runner_connection.dart';
import 'package:raccoon_runtime/src/runner_endpoint.dart';
import 'package:raccoon_runtime/src/runner_transport.dart';

/// Serves one platform channel for the hosted app, the way a desktop
/// embedder's plugin would. Returns the reply bytes, or null for "no plugin",
/// which the app sees as a null reply.
typedef PlatformChannelHandler = Future<Uint8List?> Function(Uint8List data);

/// A connection to one runner: frames, logs and platform messages in; resize,
/// input and platform replies out.
final class RunnerClient implements RunnerConnection {
  RunnerClient._(this._transport) {
    _subscription = _transport.inbound.listen(
      _onInbound,
      onDone: _onDone,
      onError: _onError,
    );
    send(
      ClientMessage(
        hello: ClientHello(
          protocolVersion: RaccoonProtocol.version,
          clientName: 'raccoon_runtime',
          sharedBuffers: _transport.receivesHandles,
        ),
      ),
    );
  }

  /// Connects to the runner at [endpoint] and sends the client hello.
  static Future<RunnerClient> connect(RunnerEndpoint endpoint) async =>
      RunnerClient._(await RunnerTransport.connect(endpoint));

  final RunnerTransport _transport;
  final _handles = <RandomAccessFile>[];
  var _buffers = <RandomAccessFile>[];
  var _sharedFrames = 0;
  final _unframer = MessageUnframer();
  final _messages = StreamController<RunnerMessage>.broadcast();
  final _hello = Completer<RunnerHello>();
  final _closed = Completer<void>();
  final _channels = <String, PlatformChannelHandler>{};
  late final StreamSubscription<Inbound> _subscription;
  Frame? _latestFrame;
  String? _vmServiceUri;
  int? _pid;

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

  /// The runner's process id once it said hello.
  int? get pid => _pid;

  /// Frames that arrived through shared buffers rather than inline.
  int get sharedFrames => _sharedFrames;

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

  /// Serves [channel] with [handler]. Channels without a handler get a
  /// "no plugin" reply.
  void registerChannel(String channel, PlatformChannelHandler handler) {
    _channels[channel] = handler;
  }

  void unregisterChannel(String channel) => _channels.remove(channel);

  void send(ClientMessage message) {
    if (_closed.isCompleted) return;
    _transport.write(MessageFraming.frame(message.writeToBuffer()));
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _transport.close();
    _finish();
  }

  void _onInbound(Inbound inbound) {
    _handles.addAll(inbound.handles);
    for (final payload in _unframer.add(inbound.bytes)) {
      final message = RunnerMessage.fromBuffer(payload);
      if (message.hasHello() && !_hello.isCompleted) {
        _pid = message.hello.pid;
        _hello.complete(message.hello);
      }
      if (message.hasSharedBuffers()) _takeBuffers(message.sharedBuffers);
      if (message.hasFrame()) {
        final frame = _resolveFrame(message.frame);
        if (frame == null) continue;
        message.frame = frame;
        _latestFrame = frame;
      }
      if (message.hasVmService()) _vmServiceUri = message.vmService.uri;
      if (message.hasPlatformMessage()) {
        unawaited(_servePlatformMessage(message.platformMessage));
      }
      _messages.add(message);
    }
  }

  Future<void> _servePlatformMessage(PlatformMessage message) async {
    final handler = _channels[message.channel];
    Uint8List? reply;
    if (handler != null) {
      try {
        reply = await handler(Uint8List.fromList(message.data));
      } on Object catch (error, stackTrace) {
        _messages.addError(error, stackTrace);
      }
    }
    if (message.responseId == 0) return;
    send(
      ClientMessage(
        platformResponse: PlatformResponse(
          responseId: message.responseId,
          handled: reply != null,
          data: reply ?? const [],
        ),
      ),
    );
  }

  /// Adopts the descriptors that travelled with [buffers], in index order.
  void _takeBuffers(SharedBuffers buffers) {
    for (final old in _buffers) {
      old.closeSync();
    }
    final count = buffers.count;
    if (_handles.length < count) {
      _buffers = [];
      _handles.clear();
      return;
    }
    _buffers = _handles.sublist(0, count);
    _handles.removeRange(0, count);
  }

  /// Reads a shared-buffer frame's pixels and gives the buffer back; an
  /// inline frame is returned as is.
  Frame? _resolveFrame(Frame frame) {
    if (!frame.inSharedBuffer) return frame;
    final index = frame.bufferIndex;
    if (index >= _buffers.length) return null;
    final file = _buffers[index]..setPositionSync(0);
    final pixels = file.readSync(frame.rowBytes * frame.height);
    send(ClientMessage(releaseBuffer: ReleaseBuffer(index: index)));
    _sharedFrames++;
    return frame.deepCopy()
      ..pixels = pixels
      ..inSharedBuffer = false;
  }

  void _onDone() => _finish();

  void _onError(Object error, StackTrace stackTrace) {
    _messages.addError(error, stackTrace);
    _finish();
  }

  void _finish() {
    if (_closed.isCompleted) return;
    _closed.complete();
    for (final buffer in _buffers) {
      buffer.closeSync();
    }
    _buffers = [];
    unawaited(_messages.close());
  }
}

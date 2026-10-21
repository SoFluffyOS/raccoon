import 'dart:async';
import 'dart:io';
import 'dart:io' as io show pid;
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
final class RunnerClient
    implements RunnerConnection, ComposingConnection, GpuBufferConnection {
  RunnerClient._(
    this._transport, {
    required this.composes,
    required this.gpuBuffers,
  }) {
    _subscription = _transport.inbound.listen(
      _onInbound,
      onDone: _onDone,
      onError: _onError,
    );
    send(
      ClientMessage(
        hello: ClientHello(
          pid: io.pid,
          composes: composes,
          gpuBuffers: gpuBuffers,
          protocolVersion: RaccoonProtocol.version,
          clientName: 'raccoon_runtime',
          sharedBuffers: _transport.receivesHandles,
        ),
      ),
    );
  }

  /// Connects to the runner at [endpoint] and sends the client hello.
  /// Connects to the runner at [endpoint] and sends the client hello. With
  /// [composes] the client promises to mirror the app's active text field in
  /// its own input method and to send what it produces; the runner then
  /// leaves typing characters to it.
  static Future<RunnerClient> connect(
    RunnerEndpoint endpoint, {
    bool composes = false,
    bool gpuBuffers = false,
  }) async => RunnerClient._(
    await RunnerTransport.connect(endpoint),
    composes: composes,
    gpuBuffers: gpuBuffers,
  );

  /// Whether this client asked for GPU buffers: frames then arrive as buffer
  /// indices ([Frame.inGpuBuffer]) with no pixels, and the buffers' file
  /// descriptors are served on the runner's GPU socket
  /// ([GpuBuffers.socket]) for the host's native side to import.
  @override
  final bool gpuBuffers;

  GpuBuffers? _latestGpuBuffers;

  /// The current set of GPU buffers, once the runner described it.
  @override
  GpuBuffers? get latestGpuBuffers => _latestGpuBuffers;

  /// Each set of GPU buffers as the runner describes it, the latest first.
  @override
  Stream<GpuBuffers> get gpuBufferSets async* {
    if (_latestGpuBuffers case final set?) yield set;
    yield* messages
        .where((message) => message.hasGpuBuffers())
        .map((message) => message.gpuBuffers);
  }

  /// Gives a GPU buffer back to the runner once the host is done with it.
  @override
  void releaseGpuBuffer(int generation, int index) => send(
    ClientMessage(
      releaseBuffer: ReleaseBuffer(index: index, generation: generation),
    ),
  );

  @override
  final bool composes;

  final RunnerTransport _transport;
  final _handles = <RandomAccessFile>[];
  var _buffers = <RandomAccessFile>[];
  var _sharedFrames = 0;
  final _unframer = MessageUnframer();
  final _messages = StreamController<RunnerMessage>.broadcast();
  final _hello = Completer<RunnerHello>()..future.ignore();
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

  @override
  void sendTextEditing(TextEditing editing) =>
      send(ClientMessage(textEditing: editing));

  TextField? _latestTextField;

  @override
  TextField? get latestTextField => _latestTextField;

  @override
  Stream<TextField> get textFields async* {
    if (_latestTextField case final field?) yield field;
    yield* messages
        .where((message) => message.hasTextField())
        .map((message) => message.textField);
  }

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
      if (message.hasBusy() && !_hello.isCompleted) {
        _hello.completeError(RunnerBusy(message.busy.pid));
      }
      if (message.hasSharedBuffers()) _takeBuffers(message.sharedBuffers);
      if (message.hasGpuBuffers()) _latestGpuBuffers = message.gpuBuffers;
      if (message.hasFrame()) {
        final frame = _resolveFrame(message.frame);
        if (frame == null) continue;
        message.frame = frame;
        _latestFrame = frame;
      }
      if (message.hasVmService()) _vmServiceUri = message.vmService.uri;
      if (message.hasTextField()) _latestTextField = message.textField;
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
    // A GPU buffer frame has no pixels here: the host's native side has the
    // buffer, and gives it back through releaseGpuBuffer.
    if (frame.inGpuBuffer) return frame;
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

/// Another client has the runner: it said so and hung up. [pid] is that
/// client's process, 0 when it did not name itself.
class RunnerBusy implements Exception {
  const RunnerBusy(this.pid);

  final int pid;

  @override
  String toString() => 'another client (pid $pid) has this runner';
}

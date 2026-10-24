import 'dart:async';
import 'dart:io';
import 'dart:io' as io show pid;
import 'dart:typed_data';

import 'package:raccoon/raccoon.dart';
import 'package:raccoon_runtime/src/message_framing.dart';
import 'package:raccoon_runtime/src/runner_connection.dart';
import 'package:raccoon_runtime/src/runner_endpoint.dart';
import 'package:raccoon_runtime/src/runner_transport.dart';
import 'package:raccoon_runtime/src/startup_failure.dart';

/// A connection to one runner: frames, logs and platform messages in; resize,
/// input and platform replies out.
final class RunnerClient
    implements
        RunnerConnection,
        ComposingConnection,
        GpuBufferConnection,
        ChannelConnection {
  RunnerClient._(
    this._transport, {
    required this.composes,
    required this.gpuBuffers,
    required this.startupGrace,
  }) {
    _subscription = _transport.inbound.listen(
      _onInbound,
      onDone: _onDone,
      onError: _onError,
    );
    _sayHello(sharedBuffers: _transport.receivesHandles);
  }

  void _sayHello({required bool sharedBuffers}) => send(
    ClientMessage(
      hello: ClientHello(
        pid: io.pid,
        composes: composes,
        gpuBuffers: gpuBuffers,
        protocolVersion: RaccoonProtocol.version,
        clientName: 'raccoon_runtime',
        sharedBuffers: sharedBuffers,
      ),
    ),
  );

  /// Connects to the runner at [endpoint] and sends the client hello.
  /// Connects to the runner at [endpoint] and sends the client hello. With
  /// [composes] the client promises to mirror the app's active text field in
  /// its own input method and to send what it produces; the runner then
  /// leaves typing characters to it.
  ///
  /// [startupGrace] is how long a failure in the app's log may go without a
  /// frame before [startupFailure] reports it.
  static Future<RunnerClient> connect(
    RunnerEndpoint endpoint, {
    bool composes = false,
    bool gpuBuffers = false,
    Duration startupGrace = defaultStartupGrace,
  }) async => RunnerClient._(
    await RunnerTransport.connect(endpoint),
    composes: composes,
    gpuBuffers: gpuBuffers,
    startupGrace: startupGrace,
  );

  /// See [startupGrace].
  static const defaultStartupGrace = Duration(seconds: 1);

  /// How long the app's log may tell of a failure before its first frame,
  /// an exception nothing caught or a channel nothing answered, with no
  /// frame following, before [startupFailure] says the app stopped. An app
  /// that catches the error and goes on draws well within it.
  final Duration startupGrace;

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
  // Which set _buffers is, as the runner named it; releases name it back,
  // so one meant for a set since replaced frees nothing in the new (#135).
  var _sharedGeneration = 0;
  var _sharedFrames = 0;
  final _unframer = MessageUnframer();
  final _messages = StreamController<RunnerMessage>.broadcast();
  final _channelErrors = StreamController<Object>.broadcast();
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

  /// What channel handlers threw. The call is answered "not handled", and
  /// the connection goes on: an error here is the handler's, not the
  /// runner's, so it stays out of [messages] and the streams built on it.
  Stream<Object> get channelErrors => _channelErrors.stream;

  /// The runner's frames as they come, the latest first when it has
  /// pixels. One in a GPU buffer is not replayed: a listener before may
  /// have given that buffer back, and showing it, then giving it back
  /// again, frees a buffer the runner may be drawing into (#145). A view
  /// sends its size as it lays out, which draws a fresh frame.
  @override
  Stream<Frame> get frames async* {
    if (_latestFrame case final frame? when !frame.inGpuBuffer) yield frame;
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

  Plugins? _latestPlugins;

  /// What became of the project's native plugins on the runner's host, as
  /// the runner last said; null until it has.
  Plugins? get latestPlugins => _latestPlugins;

  /// The latest word on the plugins first, then every change.
  Stream<Plugins> get plugins async* {
    if (_latestPlugins case final plugins?) yield plugins;
    yield* messages
        .where((message) => message.hasPlugins())
        .map((message) => message.plugins);
  }

  @override
  Stream<TextField> get textFields async* {
    if (_latestTextField case final field?) yield field;
    yield* messages
        .where((message) => message.hasTextField())
        .map((message) => message.textField);
  }

  final _startupLog = <String>[];
  StartupFailure? _startupFailure;
  Timer? _startupTimer;
  final _startupChanges = StreamController<StartupFailure?>.broadcast();

  /// The most lines of the app's log kept from before its first frame.
  static const startupLogLines = 500;

  /// The app's log lines from before its first frame, as the runner relays
  /// them (its stderr among them); empty once a frame arrived.
  List<String> get startupLog => List.unmodifiable(_startupLog);

  /// Why the app stopped before its first frame: its log tells of a
  /// failure and no frame followed within [startupGrace]. Null otherwise,
  /// and for good once a frame arrived: from then on the app's own error
  /// handling rules.
  StartupFailure? get startupFailure => _startupFailure;

  /// The current [startupFailure] first, then every change.
  Stream<StartupFailure?> get startupFailures async* {
    yield _startupFailure;
    yield* _startupChanges.stream;
  }

  /// Asks the runner to stop.
  void shutdown() => send(ClientMessage(shutdown: Shutdown()));

  /// Serves [channel] with [handler]. Channels without a handler get a
  /// "no plugin" reply.
  @override
  void registerChannel(String channel, PlatformChannelHandler handler) {
    _channels[channel] = handler;
  }

  @override
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
        if (_latestFrame == null) _startupOver();
        _latestFrame = frame;
      }
      if (message.hasVmService()) _vmServiceUri = message.vmService.uri;
      if (message.hasTextField()) _latestTextField = message.textField;
      if (message.hasPlugins()) {
        _latestPlugins = message.plugins;
        if (_latestFrame == null) _readStartup();
      }
      if (message.hasLog() && _latestFrame == null) {
        _startupLog.add(message.log.message);
        final overflow = _startupLog.length - startupLogLines;
        if (overflow > 0) _startupLog.removeRange(0, overflow);
        _readStartup();
      }
      if (message.hasPlatformMessage()) {
        unawaited(_servePlatformMessage(message.platformMessage));
      }
      _messages.add(message);
    }
  }

  /// Reads the log again. A failure already reported is brought up to date
  /// at once (the plugin report may come after the lines); a new one waits
  /// out [startupGrace].
  void _readStartup() {
    final found = StartupFailure.fromLog(_startupLog, plugins: _latestPlugins);
    if (found == null) return;
    if (_startupFailure != null) {
      _reportStartup(found);
      return;
    }
    // The grace runs from the failure, not from the latest line: an app
    // that goes on logging after it died is reported all the same.
    if (_startupTimer?.isActive ?? false) return;
    _startupTimer = Timer(startupGrace, () {
      if (_latestFrame != null || _closed.isCompleted) return;
      _reportStartup(
        StartupFailure.fromLog(_startupLog, plugins: _latestPlugins),
      );
    });
  }

  void _reportStartup(StartupFailure? failure) {
    if (failure == _startupFailure) return;
    _startupFailure = failure;
    _startupChanges.add(failure);
  }

  /// The first frame: whatever the log said, the app is drawing.
  void _startupOver() {
    _startupTimer?.cancel();
    _startupTimer = null;
    _startupLog.clear();
    _reportStartup(null);
  }

  Future<void> _servePlatformMessage(PlatformMessage message) async {
    final handler = _channels[message.channel];
    Uint8List? reply;
    if (handler != null) {
      try {
        reply = await handler(Uint8List.fromList(message.data));
      } on Object catch (error, stackTrace) {
        if (!_closed.isCompleted) _channelErrors.addError(error, stackTrace);
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
    // Descriptors arrive in order, and a later set's can come in the same
    // read as the tail of this one: the set takes its count from the front.
    // A set that came short of its count is dropped, its descriptors
    // closed rather than leaked (#134, #137).
    _sharedGeneration = buffers.generation;
    final count = buffers.count;
    if (_handles.length < count) {
      _buffers = [];
      _closeHandles();
      // The runner would go on filling buffers this client can't read:
      // it is told to send frames inline instead (#145).
      _sayHello(sharedBuffers: false);
      return;
    }
    _buffers = _handles.sublist(0, count);
    _handles.removeRange(0, count);
  }

  void _closeHandles() {
    for (final handle in _handles) {
      handle.closeSync();
    }
    _handles.clear();
  }

  /// Reads a shared-buffer frame's pixels and gives the buffer back; an
  /// inline frame is returned as is.
  Frame? _resolveFrame(Frame frame) {
    // A GPU buffer frame has no pixels here: the host's native side has the
    // buffer, and gives it back through releaseGpuBuffer.
    if (frame.inGpuBuffer) return frame;
    if (!frame.inSharedBuffer) return frame;
    final index = frame.bufferIndex;
    if (index >= _buffers.length) {
      // Not one this client holds: dropped, but given back, or the runner
      // would keep it busy and send every frame inline.
      _releaseShared(index);
      return null;
    }
    final file = _buffers[index]..setPositionSync(0);
    final pixels = file.readSync(frame.rowBytes * frame.height);
    _releaseShared(index);
    _sharedFrames++;
    return frame.deepCopy()
      ..pixels = pixels
      ..inSharedBuffer = false;
  }

  void _releaseShared(int index) => send(
    ClientMessage(
      releaseBuffer: ReleaseBuffer(
        index: index,
        sharedGeneration: _sharedGeneration,
      ),
    ),
  );

  void _onDone() => _finish();

  void _onError(Object error, StackTrace stackTrace) {
    // A socket can fail after the client already finished (a reset behind
    // the end); there is no one left to tell.
    if (_closed.isCompleted) return;
    _messages.addError(error, stackTrace);
    _finish();
  }

  void _finish() {
    if (_closed.isCompleted) return;
    _closed.complete();
    // A runner that hangs up before it says hello never will.
    if (!_hello.isCompleted) {
      _hello.completeError(
        const SocketException('the runner hung up before its hello'),
      );
    }
    _startupTimer?.cancel();
    for (final buffer in _buffers) {
      buffer.closeSync();
    }
    _buffers = [];
    _closeHandles();
    unawaited(_messages.close());
    unawaited(_channelErrors.close());
    unawaited(_startupChanges.close());
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

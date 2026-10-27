import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:raccoon_runtime/src/runner_endpoint.dart';

/// Bytes read from the runner, with any file descriptors that came along.
final class Inbound {
  const Inbound(this.bytes, this.handles);

  /// The bytes as one read gave them, not yet split into messages.
  final Uint8List bytes;

  /// The descriptors that came with them, opened as files; always empty
  /// where the socket carries none (Windows).
  final List<RandomAccessFile> handles;
}

/// The socket beneath a [RunnerClient]: raw, so descriptors can be received
/// where the host passes them, with partial writes queued until the socket
/// drains.
final class RunnerTransport {
  RunnerTransport._(this._socket, this.receivesHandles) {
    _subscription = _socket.listen(_onEvent, onError: _onError);
  }

  /// Windows sockets carry no handles, so frames come inline there.
  static Future<RunnerTransport> connect(RunnerEndpoint endpoint) async {
    final socket = switch (endpoint) {
      UnixSocketEndpoint(:final path) => await RawSocket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      ),
    };
    return RunnerTransport._(socket, !Platform.isWindows);
  }

  final RawSocket _socket;

  /// Whether file descriptors can arrive with the bytes.
  final bool receivesHandles;

  final _inbound = StreamController<Inbound>();
  // What the socket has not taken yet, written from the head: a runner that
  // stops reading costs each write nothing more than its place in line
  // (#227).
  final _pending = ListQueue<Uint8List>();
  var _head = 0;
  late final StreamSubscription<RawSocketEvent> _subscription;
  var _closed = false;
  var _runnerClosed = false;
  Completer<void>? _drained;
  Completer<void>? _hungUp;

  /// What the runner sends, a read at a time; done once either side hangs
  /// up.
  Stream<Inbound> get inbound => _inbound.stream;

  /// Sends [bytes], queueing what the socket does not take yet until it
  /// drains; ignored once closing.
  void write(Uint8List bytes) {
    if (_closed || bytes.isEmpty) return;
    _pending.add(bytes);
    // Behind others, it waits for the socket to drain them.
    if (_pending.length == 1) _flush();
  }

  /// Sends what is still queued first (a Shutdown written right before
  /// this, above all), waiting up to [drain] for the socket to take it: a
  /// runner that is gone never will. Then says it is done sending and reads
  /// until the runner hangs up, again for up to [drain]: closing with the
  /// runner's bytes unread makes Windows reset the connection, and a reset
  /// throws away what the runner had not read yet, that Shutdown included.
  Future<void> close({Duration drain = const Duration(seconds: 2)}) async {
    if (_closed) return;
    _closed = true;
    if (_pending.isNotEmpty) {
      final drained = _drained = Completer<void>();
      _socket.writeEventsEnabled = true;
      await drained.future.timeout(drain, onTimeout: () {});
    }
    if (!_runnerClosed) {
      final hungUp = _hungUp = Completer<void>();
      try {
        _socket.shutdown(SocketDirection.send);
        await hungUp.future.timeout(drain, onTimeout: () {});
      } on SocketException {
        // Gone already.
      }
    }
    await _subscription.cancel();
    await _socket.close();
    await _inbound.close();
  }

  void _flush() {
    while (_pending.isNotEmpty) {
      final bytes = _pending.first;
      final written = _socket.write(bytes, _head);
      _head += written;
      if (_head < bytes.length) {
        _socket.writeEventsEnabled = true;
        return;
      }
      _pending.removeFirst();
      _head = 0;
    }
    _completeDrained();
  }

  void _completeDrained() {
    if (_drained case final drained? when !drained.isCompleted) {
      drained.complete();
    }
  }

  /// The runner is gone: nothing queued will be taken, and the transport
  /// ends as on any hang-up.
  void _gone() {
    _runnerClosed = true;
    if (_hungUp case final hungUp? when !hungUp.isCompleted) {
      hungUp.complete();
    }
    _completeDrained();
    unawaited(close());
  }

  void _onEvent(RawSocketEvent event) {
    switch (event) {
      case RawSocketEvent.read:
        _read();
      case RawSocketEvent.write:
        _flush();
      case RawSocketEvent.readClosed:
        _runnerClosed = true;
        if (_hungUp case final hungUp? when !hungUp.isCompleted) {
          hungUp.complete();
        }
        unawaited(close());
      case RawSocketEvent.closed:
        _gone();
    }
  }

  void _read() {
    // Closing: what still comes is read only so the runner can hang up.
    if (_closed) {
      if (!receivesHandles) {
        _socket.read();
        return;
      }
      for (final control in _socket.readMessage()?.controlMessages ?? []) {
        for (final handle in control.extractHandles()) {
          handle.toFile().closeSync();
        }
      }
      return;
    }
    if (!receivesHandles) {
      // As much as is there, in one buffer: a read with no count gathers
      // it and copies it once more.
      final available = _socket.available();
      final bytes = _socket.read(available > 0 ? available : null);
      if (bytes != null) _inbound.add(Inbound(bytes, const []));
      return;
    }
    final message = _socket.readMessage();
    if (message == null) return;
    final handles = [
      for (final control in message.controlMessages)
        for (final handle in control.extractHandles()) handle.toFile(),
    ];
    _inbound.add(Inbound(message.data, handles));
  }

  void _onError(Object error, StackTrace stackTrace) {
    // A write that fails (Broken pipe) is a runner that is gone, as when it
    // exits while a Shutdown or a pointer is on its way: it hung up, which
    // ends the transport as any hang-up does, and is nobody's error (#90).
    // So is a reset, which Linux and Windows give a read when the runner
    // exits with what the host sent still unread (#227).
    if (error is SocketException &&
        (error.message.startsWith('Write failed') ||
            _resets.contains(error.osError?.errorCode))) {
      _gone();
      return;
    }
    _inbound.addError(error, stackTrace);
    unawaited(close());
  }

  /// ECONNRESET on macOS and Linux, WSAECONNRESET on Windows.
  static const _resets = {54, 104, 10054};
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:raccoon_runtime/src/runner_endpoint.dart';

/// Bytes read from the runner, with any file descriptors that came along.
final class Inbound {
  const Inbound(this.bytes, this.handles);

  final Uint8List bytes;
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
  final _pending = BytesBuilder(copy: false);
  late final StreamSubscription<RawSocketEvent> _subscription;
  var _closed = false;
  var _runnerClosed = false;
  Completer<void>? _drained;
  Completer<void>? _hungUp;

  Stream<Inbound> get inbound => _inbound.stream;

  void write(Uint8List bytes) {
    if (_closed) return;
    _pending.add(bytes);
    _flush();
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
    if (_pending.isNotEmpty) {
      final bytes = _pending.takeBytes();
      final written = _socket.write(bytes);
      if (written < bytes.length) {
        _pending.add(Uint8List.sublistView(bytes, written));
        _socket.writeEventsEnabled = true;
        return;
      }
    }
    if (_drained case final drained? when !drained.isCompleted) {
      drained.complete();
    }
  }

  void _onEvent(RawSocketEvent event) {
    switch (event) {
      case RawSocketEvent.read:
        _read();
      case RawSocketEvent.write:
        _flush();
      case RawSocketEvent.readClosed:
      case RawSocketEvent.closed:
        _runnerClosed = true;
        if (_hungUp case final hungUp? when !hungUp.isCompleted) {
          hungUp.complete();
        }
        unawaited(close());
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
      final bytes = _socket.read();
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
    _inbound.addError(error, stackTrace);
    unawaited(close());
  }
}

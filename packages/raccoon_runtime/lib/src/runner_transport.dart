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
  Completer<void>? _drained;

  Stream<Inbound> get inbound => _inbound.stream;

  void write(Uint8List bytes) {
    if (_closed) return;
    _pending.add(bytes);
    _flush();
  }

  /// Sends what is still queued first (a Shutdown written right before
  /// this, above all), waiting up to [drain] for the socket to take it: a
  /// runner that is gone never will.
  Future<void> close({Duration drain = const Duration(seconds: 2)}) async {
    if (_closed) return;
    _closed = true;
    if (_pending.isNotEmpty) {
      final drained = _drained = Completer<void>();
      _socket.writeEventsEnabled = true;
      await drained.future.timeout(drain, onTimeout: () {});
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
        unawaited(close());
    }
  }

  void _read() {
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

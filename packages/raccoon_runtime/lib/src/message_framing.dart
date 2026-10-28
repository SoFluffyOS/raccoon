import 'dart:typed_data';

/// The runner protocol's framing: a 4-byte little-endian length, then the
/// serialized message.
abstract final class MessageFraming {
  /// Bytes in the length prefix.
  static const int prefixLength = 4;

  /// The longest message a client takes: well past a frame's pixels at any
  /// size a host shows, short of a length a corrupt prefix would give
  /// (#227).
  static const int maxLength = 512 * 1024 * 1024;

  /// The longest message a runner takes from its client (its
  /// `kMaxMessage`): one longer and it lets the client go.
  static const int maxToRunner = 64 * 1024 * 1024;

  /// Prepends the length prefix to [payload].
  static Uint8List frame(List<int> payload) {
    final out = Uint8List(prefixLength + payload.length);
    ByteData.sublistView(out).setUint32(0, payload.length, Endian.little);
    out.setRange(prefixLength, out.length, payload);
    return out;
  }
}

/// Reassembles length-prefixed messages from a byte stream. Chunks are kept
/// as they arrive and joined once per message, so a large frame split into
/// many socket reads costs one copy, not one per read.
final class MessageUnframer {
  final _chunks = <Uint8List>[];
  var _pendingLength = 0;

  /// Why the stream stopped being the protocol: a length past
  /// [MessageFraming.maxLength]. Set by [add], which still returns the
  /// payloads before it; nothing after it is read.
  FormatException? get failure => _failure;
  FormatException? _failure;

  /// Feeds [chunk] and returns every complete payload it completed, up to
  /// a [failure].
  List<Uint8List> add(List<int> chunk) {
    if (chunk.isEmpty || _failure != null) return const [];
    _chunks.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
    _pendingLength += chunk.length;
    final payloads = <Uint8List>[];
    while (true) {
      final length = _peekLength();
      if (length != null && length > MessageFraming.maxLength) {
        _failure = FormatException(
          'a message of $length bytes is not the protocol',
        );
        _chunks.clear();
        _pendingLength = 0;
        break;
      }
      if (length == null ||
          _pendingLength < MessageFraming.prefixLength + length) {
        break;
      }
      final bytes = _take(MessageFraming.prefixLength + length);
      payloads.add(Uint8List.sublistView(bytes, MessageFraming.prefixLength));
    }
    return payloads;
  }

  /// The length prefix at the head of the pending bytes, if 4 bytes are in.
  int? _peekLength() {
    if (_pendingLength < MessageFraming.prefixLength) return null;
    final head = Uint8List(MessageFraming.prefixLength);
    var filled = 0;
    for (final chunk in _chunks) {
      final take =
          chunk.length < head.length - filled
              ? chunk.length
              : head.length - filled;
      head.setRange(filled, filled + take, chunk);
      filled += take;
      if (filled == head.length) break;
    }
    return ByteData.sublistView(head).getUint32(0, Endian.little);
  }

  /// Removes and returns the first [count] pending bytes as one buffer: a
  /// view of the first chunk when they are all in it, else joined.
  Uint8List _take(int count) {
    final first = _chunks.first;
    if (first.length >= count) {
      if (first.length == count) {
        _chunks.removeAt(0);
      } else {
        _chunks[0] = Uint8List.sublistView(first, count);
      }
      _pendingLength -= count;
      return Uint8List.sublistView(first, 0, count);
    }
    final out = Uint8List(count);
    var filled = 0;
    while (filled < count) {
      final chunk = _chunks.first;
      final take =
          chunk.length < count - filled ? chunk.length : count - filled;
      out.setRange(filled, filled + take, chunk);
      filled += take;
      if (take == chunk.length) {
        _chunks.removeAt(0);
      } else {
        _chunks[0] = Uint8List.sublistView(chunk, take);
      }
    }
    _pendingLength -= count;
    return out;
  }
}

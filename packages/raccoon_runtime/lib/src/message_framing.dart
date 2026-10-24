import 'dart:typed_data';

/// The runner protocol's framing: a 4-byte little-endian length, then the
/// serialized message.
abstract final class MessageFraming {
  /// Bytes in the length prefix.
  static const int prefixLength = 4;

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

  /// Feeds [chunk] and returns every complete payload it completed.
  List<Uint8List> add(List<int> chunk) {
    if (chunk.isEmpty) return const [];
    _chunks.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
    _pendingLength += chunk.length;
    final payloads = <Uint8List>[];
    while (true) {
      final length = _peekLength();
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

  /// Removes and returns the first [count] pending bytes as one buffer.
  Uint8List _take(int count) {
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

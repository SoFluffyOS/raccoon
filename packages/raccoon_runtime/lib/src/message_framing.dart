import 'dart:typed_data';

/// The runner protocol's framing: a 4-byte little-endian length, then the
/// serialized message.
abstract final class MessageFraming {
  static const int prefixLength = 4;

  /// Prepends the length prefix to [payload].
  static Uint8List frame(List<int> payload) {
    final out = Uint8List(prefixLength + payload.length);
    ByteData.sublistView(out).setUint32(0, payload.length, Endian.little);
    out.setRange(prefixLength, out.length, payload);
    return out;
  }
}

/// Reassembles length-prefixed messages from a byte stream.
final class MessageUnframer {
  final _pending = BytesBuilder(copy: false);

  /// Feeds [chunk] and returns every complete payload it completed.
  List<Uint8List> add(List<int> chunk) {
    _pending.add(chunk);
    final bytes = _pending.toBytes();
    final data = ByteData.sublistView(bytes);
    final payloads = <Uint8List>[];
    var offset = 0;
    while (bytes.length - offset >= MessageFraming.prefixLength) {
      final length = data.getUint32(offset, Endian.little);
      final start = offset + MessageFraming.prefixLength;
      if (bytes.length - start < length) break;
      payloads.add(Uint8List.sublistView(bytes, start, start + length));
      offset = start + length;
    }
    _pending.clear();
    if (offset < bytes.length) {
      _pending.add(Uint8List.sublistView(bytes, offset));
    }
    return payloads;
  }
}

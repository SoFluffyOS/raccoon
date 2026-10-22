import 'package:flutter/services.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart' show ChannelConnection;

/// The hosted app's mouse cursor: what it activates on `flutter/mousecursor`
/// (a text beam over a field, a hand over a link), as one of Flutter's own
/// [SystemMouseCursors], for the view to show over the app.
final class HostedMouseCursor {
  HostedMouseCursor(this._connection, this._onChanged) {
    _connection.registerChannel(channel, _handle);
  }

  static const String channel = 'flutter/mousecursor';
  static const MethodCodec _codec = StandardMethodCodec();

  final ChannelConnection _connection;
  final void Function(MouseCursor cursor) _onChanged;

  /// Stops taking the app's cursor; the connection answers "no plugin" again.
  void detach() => _connection.unregisterChannel(channel);

  Future<Uint8List?> _handle(Uint8List data) async {
    final call = _codec.decodeMethodCall(ByteData.sublistView(data));
    if (call.method != 'activateSystemCursor') return null;
    final kind = (call.arguments as Map?)?['kind'] as String?;
    _onChanged(_byKind[kind] ?? SystemMouseCursors.basic);
    final reply = _codec.encodeSuccessEnvelope(null);
    return reply.buffer.asUint8List(reply.offsetInBytes, reply.lengthInBytes);
  }

  /// Every system cursor by the kind the framework names it with.
  static final Map<String, MouseCursor> _byKind = {
    for (final cursor in <SystemMouseCursor>[
      SystemMouseCursors.none,
      SystemMouseCursors.basic,
      SystemMouseCursors.click,
      SystemMouseCursors.forbidden,
      SystemMouseCursors.wait,
      SystemMouseCursors.progress,
      SystemMouseCursors.contextMenu,
      SystemMouseCursors.help,
      SystemMouseCursors.text,
      SystemMouseCursors.verticalText,
      SystemMouseCursors.cell,
      SystemMouseCursors.precise,
      SystemMouseCursors.move,
      SystemMouseCursors.grab,
      SystemMouseCursors.grabbing,
      SystemMouseCursors.noDrop,
      SystemMouseCursors.alias,
      SystemMouseCursors.copy,
      SystemMouseCursors.disappearing,
      SystemMouseCursors.allScroll,
      SystemMouseCursors.resizeLeftRight,
      SystemMouseCursors.resizeUpDown,
      SystemMouseCursors.resizeUpLeftDownRight,
      SystemMouseCursors.resizeUpRightDownLeft,
      SystemMouseCursors.resizeUp,
      SystemMouseCursors.resizeDown,
      SystemMouseCursors.resizeLeft,
      SystemMouseCursors.resizeRight,
      SystemMouseCursors.resizeUpLeft,
      SystemMouseCursors.resizeUpRight,
      SystemMouseCursors.resizeDownLeft,
      SystemMouseCursors.resizeDownRight,
      SystemMouseCursors.resizeColumn,
      SystemMouseCursors.resizeRow,
      SystemMouseCursors.zoomIn,
      SystemMouseCursors.zoomOut,
    ])
      cursor.kind: cursor,
  };
}

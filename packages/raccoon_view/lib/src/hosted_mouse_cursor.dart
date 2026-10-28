import 'package:flutter/services.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart' show ChannelConnection;

/// The hosted app's mouse cursor: what it activates on `flutter/mousecursor`
/// (a text beam over a field, a hand over a link), as one of Flutter's own
/// [SystemMouseCursors], for the view to show over the app.
final class HostedMouseCursor {
  /// Views of one connection share its channel, which has one handler:
  /// each is told every change, and the channel goes with the last (#232).
  HostedMouseCursor(this._connection, this._onChanged) {
    _watchers
        .putIfAbsent(_connection, () {
          _connection.registerChannel(
            channel,
            (data) => _handle(_connection, data),
          );
          return <HostedMouseCursor>{};
        })
        .add(this);
  }

  static const String channel = 'flutter/mousecursor';
  static const MethodCodec _codec = StandardMethodCodec();

  static final _watchers =
      Map<ChannelConnection, Set<HostedMouseCursor>>.identity();

  final ChannelConnection _connection;
  final void Function(MouseCursor cursor) _onChanged;

  /// Stops taking the app's cursor; once no view of the connection takes
  /// it, the connection answers "no plugin" again.
  void detach() {
    final watchers = _watchers[_connection];
    if (watchers == null || !watchers.remove(this) || watchers.isNotEmpty) {
      return;
    }
    _watchers.remove(_connection);
    _connection.unregisterChannel(channel);
  }

  static Future<Uint8List?> _handle(
    ChannelConnection connection,
    Uint8List data,
  ) async {
    final call = _codec.decodeMethodCall(ByteData.sublistView(data));
    if (call.method != 'activateSystemCursor') return null;
    final kind = (call.arguments as Map?)?['kind'] as String?;
    final cursor = _byKind[kind] ?? SystemMouseCursors.basic;
    for (final watcher in [...?_watchers[connection]]) {
      watcher._onChanged(cursor);
    }
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

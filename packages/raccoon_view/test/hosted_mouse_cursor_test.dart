import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raccoon/raccoon.dart' as rc;
import 'package:raccoon_runtime/raccoon_runtime.dart'
    show ChannelConnection, PlatformChannelHandler, RunnerConnection;
import 'package:raccoon_view/raccoon_view.dart';

/// A connection that serves the app's channels: what the view registers is
/// kept, so the test can call it as the app would.
class _ChannelConnection implements RunnerConnection, ChannelConnection {
  final channels = <String, PlatformChannelHandler>{};

  @override
  Stream<rc.Frame> get frames => const Stream.empty();

  @override
  void resize(int width, int height, double pixelRatio) {}

  @override
  void sendPointer(rc.PointerEvent event) {}

  @override
  void sendKey(rc.KeyEvent event) {}

  @override
  void registerChannel(String channel, PlatformChannelHandler handler) =>
      channels[channel] = handler;

  @override
  void unregisterChannel(String channel) => channels.remove(channel);
}

class _PlainConnection implements RunnerConnection {
  @override
  Stream<rc.Frame> get frames => const Stream.empty();

  @override
  void resize(int width, int height, double pixelRatio) {}

  @override
  void sendPointer(rc.PointerEvent event) {}

  @override
  void sendKey(rc.KeyEvent event) {}
}

const _codec = StandardMethodCodec();

Uint8List _call(String method, [Object? arguments]) {
  final data = _codec.encodeMethodCall(MethodCall(method, arguments));
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

MouseCursor _viewCursor(WidgetTester tester) =>
    tester
        .widget<MouseRegion>(
          find.descendant(
            of: find.byType(RaccoonView),
            matching: find.byType(MouseRegion),
          ),
        )
        .cursor;

void main() {
  testWidgets('shows the cursor the app activates', (tester) async {
    final connection = _ChannelConnection();
    await tester.pumpWidget(RaccoonView(connection: connection));
    expect(_viewCursor(tester), MouseCursor.defer);

    final handler = connection.channels['flutter/mousecursor'];
    expect(handler, isNotNull);
    final reply = await handler!(
      _call('activateSystemCursor', {'device': 1, 'kind': 'text'}),
    );
    await tester.pump();

    expect(_viewCursor(tester), SystemMouseCursors.text);
    expect(_codec.decodeEnvelope(ByteData.sublistView(reply!)), isNull);

    await handler(_call('activateSystemCursor', {'device': 1, 'kind': 'x'}));
    await tester.pump();
    expect(_viewCursor(tester), SystemMouseCursors.basic);

    expect(await handler(_call('somethingElse')), isNull);
  });

  testWidgets('gives the channel back when it goes', (tester) async {
    final connection = _ChannelConnection();
    await tester.pumpWidget(RaccoonView(connection: connection));
    expect(connection.channels, contains('flutter/mousecursor'));

    await tester.pumpWidget(const SizedBox());
    expect(connection.channels, isEmpty);
  });

  testWidgets('defers without a connection that serves channels', (
    tester,
  ) async {
    await tester.pumpWidget(RaccoonView(connection: _PlainConnection()));
    expect(_viewCursor(tester), MouseCursor.defer);
  });
}

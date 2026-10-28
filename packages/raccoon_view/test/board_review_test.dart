// Findings of a review of the board and the canvas, each failing before its
// fix (#233).
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raccoon/raccoon.dart' as proto;
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:raccoon_view/raccoon_view.dart';

final class _Connection implements RunnerConnection {
  final _frames = StreamController<proto.Frame>.broadcast();
  final pointers = <proto.PointerEvent>[];
  @override
  Stream<proto.Frame> get frames => _frames.stream;
  @override
  void resize(int width, int height, double pixelRatio) {}
  @override
  void sendPointer(proto.PointerEvent event) => pointers.add(event);
  @override
  void sendKey(proto.KeyEvent event) {}
}

void main() {
  late RaccoonBoardLayout layout;
  setUp(() => layout = RaccoonBoardLayout());

  Future<void> pumpBoard(
    WidgetTester tester,
    List<RaccoonBoardSession> sessions, {
    ValueChanged<RaccoonBoardMenuRequest>? onContextMenu,
  }) async {
    tester.view
      ..physicalSize = const Size(2400, 1600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RaccoonBoard(
          sessions: sessions,
          layout: layout,
          onContextMenu: onContextMenu,
        ),
      ),
    );
  }

  testWidgets('Ctrl and the wheel over an app zoom the board, and the app '
      'gets no scroll', (tester) async {
    final connection = _Connection();
    await pumpBoard(tester, [
      RaccoonBoardSession(name: 'counter', connection: connection),
    ]);
    final app = tester.getRect(find.byType(RaccoonView));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(app.center));
    await tester.pump();
    final before = connection.pointers.length;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -100)));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(
      tester.getRect(find.byType(RaccoonView)).width,
      greaterThan(app.width),
    );
    expect(
      connection.pointers.skip(before).where((e) => e.scrollDeltaY != 0),
      isEmpty,
    );
  });

  testWidgets('an app that fits below the least zoom zooms out no further, '
      'not in', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 800,
            height: 600,
            child: RaccoonCanvas(
              size: Size(4000, 3000),
              child: ColoredBox(color: Color(0xFF123456)),
            ),
          ),
        ),
      ),
    );
    final before = tester.getRect(find.byType(ColoredBox));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(const Offset(400, 300));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(
      tester.getRect(find.byType(ColoredBox)).width,
      lessThanOrEqualTo(before.width),
    );
  });

  testWidgets('the resize corner stays with the pointer past the least size, '
      'and the title fits', (tester) async {
    await pumpBoard(tester, [
      RaccoonBoardSession(name: 'counter', connection: _Connection()),
    ]);
    final handle = tester.getCenter(
      find.byKey(RaccoonBoard.resizeKey('counter')),
    );
    final gesture = await tester.startGesture(handle);
    await gesture.moveBy(const Offset(-20, 0));
    await gesture.moveBy(const Offset(-1000, 0));
    await tester.pump();
    // Back 200, still far left of a corner at the least width.
    await gesture.moveBy(const Offset(200, 0));
    await tester.pump();
    await gesture.up();

    expect(layout.frameFor('counter').size.width, RaccoonBoardFrame.minSide);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a menu action picked after the board went does nothing', (
    tester,
  ) async {
    final asked = <RaccoonBoardMenuRequest>[];
    await pumpBoard(tester, [
      RaccoonBoardSession(name: 'counter', connection: _Connection()),
    ], onContextMenu: asked.add);
    await tester.tapAt(const Offset(2000, 1400), buttons: kSecondaryButton);
    await tester.pumpWidget(const SizedBox());

    asked.single
      ..zoomIn()
      ..zoomOut()
      ..resetZoom()
      ..showAll();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a starting and a running session of one name make one frame', (
    tester,
  ) async {
    await pumpBoard(tester, [
      const RaccoonBoardSession.starting(name: 'counter', status: 'building'),
      RaccoonBoardSession(name: 'counter', connection: _Connection()),
    ]);

    expect(tester.takeException(), isNull);
    expect(find.byType(RaccoonView), findsOneWidget);
  });
}

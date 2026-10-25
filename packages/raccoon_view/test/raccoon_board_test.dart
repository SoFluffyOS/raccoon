import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raccoon/raccoon.dart' as proto;
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:raccoon_view/raccoon_view.dart';

/// A connection that records what the view sends.
final class _FakeConnection implements RunnerConnection {
  final _frames = StreamController<proto.Frame>.broadcast();
  final resizes = <({int width, int height, double pixelRatio})>[];
  final pointers = <proto.PointerEvent>[];

  @override
  Stream<proto.Frame> get frames => _frames.stream;

  @override
  void resize(int width, int height, double pixelRatio) =>
      resizes.add((width: width, height: height, pixelRatio: pixelRatio));

  @override
  void sendPointer(proto.PointerEvent event) => pointers.add(event);

  @override
  void sendKey(proto.KeyEvent event) {}
}

/// A layout that counts its saves.
final class _CountingLayout extends RaccoonBoardLayout {
  var changes = 0;

  @override
  void didChange() => changes++;
}

void main() {
  group('RaccoonBoardFrame', () {
    test('a sized device gets its size and ratio', () {
      final frame = RaccoonBoardFrame.initial('wonders@tablet');
      expect(frame.size, const Size(820, 1180));
      expect(frame.pixelRatio, 2);
      expect(frame.device, 'Raccoon Tablet');
      expect(frame.project, 'wonders');
      expect(frame.title, 'Raccoon Tablet · wonders');
      expect(frame.label, '820 × 1180 · 2x');
    });

    test('a plain name gets a phone-sized frame', () {
      final frame = RaccoonBoardFrame.initial('counter');
      expect(frame.size, const Size(390, 844));
      expect(frame.pixelRatio, 2);
      expect(frame.device, 'Raccoon');
      expect(
        frame.position,
        const Offset(RaccoonBoardFrame.gap, RaccoonBoardFrame.gap),
      );
    });

    test('a new frame goes right of the ones there', () {
      final first = RaccoonBoardFrame.initial('a');
      final second = RaccoonBoardFrame.initial('b@desktop', existing: [first]);
      expect(
        second.position.dx,
        first.position.dx + 390 + RaccoonBoardFrame.gap,
      );
      expect(second.position.dy, RaccoonBoardFrame.gap);
      final third = RaccoonBoardFrame.initial('c', existing: [first, second]);
      expect(
        third.position.dx,
        second.position.dx + 1280 + RaccoonBoardFrame.gap,
      );
    });

    test('round-trips through json', () {
      final frame = RaccoonBoardFrame.initial(
        'wonders@2',
      ).copyWith(position: const Offset(10, 20), size: const Size(300, 400));
      final back = RaccoonBoardFrame.fromJson(frame.toJson());
      expect(back.name, 'wonders@2');
      expect(back.position, const Offset(10, 20));
      expect(back.size, const Size(300, 400));
      expect(back.pixelRatio, 2);
      expect(back.device, 'Raccoon 2');
    });
  });

  group('RaccoonBoardLayout', () {
    test('frames are made on first sight, next to each other', () {
      final layout = _CountingLayout();
      final first = layout.frameFor('a');
      final second = layout.frameFor('b@tablet');
      expect(layout.frameFor('a'), same(first));
      expect(second.position.dx, greaterThan(first.position.dx + 390));
      expect(layout.frames, [first, second]);
      expect(layout.changes, 2);
    });

    test('moving and resizing tell listeners and clamp the size', () {
      final layout = _CountingLayout();
      var told = 0;
      layout.addListener(() => told++);
      layout.frameFor('a');

      layout.move('a', const Offset(100, 200));
      expect(layout.frameFor('a').position, const Offset(100, 200));
      expect(told, 1);

      layout.resize('a', const Size(10, 500));
      expect(
        layout.frameFor('a').size,
        const Size(RaccoonBoardFrame.minSide, 500),
      );
      expect(told, 2);
      expect(layout.changes, 3);

      layout.move('nobody', Offset.zero);
      layout.resize('nobody', const Size(1, 1));
      expect(told, 2);
    });

    test('a layout round-trips through json, and bad text is no layout', () {
      final layout = RaccoonBoardLayout();
      layout.frameFor('a');
      layout.move('a', const Offset(5, 6));
      final frames = RaccoonBoardLayout.parse(layout.toJson());
      expect(frames.single.position, const Offset(5, 6));
      expect(RaccoonBoardLayout.parse('not json'), isEmpty);

      final other = RaccoonBoardLayout()..replaceAll(frames);
      expect(other.frameFor('a').position, const Offset(5, 6));
    });
  });

  group('RaccoonBoard', () {
    late RaccoonBoardLayout layout;

    setUp(() => layout = RaccoonBoardLayout());

    Future<Map<String, _FakeConnection>> pumpBoard(
      WidgetTester tester,
      List<String> names, {
      Map<String, VoidCallback> onClose = const {},
      ValueChanged<RaccoonBoardMenuRequest>? onContextMenu,
    }) async {
      tester.view
        ..physicalSize = const Size(2400, 1600)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final connections = {for (final name in names) name: _FakeConnection()};
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RaccoonBoard(
            sessions: [
              for (final name in names)
                RaccoonBoardSession(
                  name: name,
                  connection: connections[name]!,
                  onClose: onClose[name],
                ),
            ],
            layout: layout,
            empty: const Text('nothing runs'),
            onContextMenu: onContextMenu,
          ),
        ),
      );
      return connections;
    }

    testWidgets('shows the host\'s empty widget while nothing runs', (
      tester,
    ) async {
      await pumpBoard(tester, []);
      expect(find.text('nothing runs'), findsOneWidget);
      expect(find.byType(RaccoonView), findsNothing);
    });

    // #133: frames were matched by place, so closing the first handed the
    // second's view, focus and all, to the third.
    testWidgets('a session keeps its view when one before it closes', (
      tester,
    ) async {
      final connections = await pumpBoard(tester, ['a', 'b', 'c']);
      State viewOf(String name) => tester.state(
        find.byWidgetPredicate(
          (widget) =>
              widget is RaccoonView && widget.connection == connections[name],
        ),
      );
      final before = viewOf('b');
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RaccoonBoard(
            sessions: [
              for (final name in ['b', 'c'])
                RaccoonBoardSession(name: name, connection: connections[name]!),
            ],
            layout: layout,
          ),
        ),
      );
      expect(viewOf('b'), same(before));
    });

    testWidgets('each session gets a frame at its device size', (tester) async {
      final connections = await pumpBoard(tester, [
        'counter',
        'wonders@tablet',
      ]);
      expect(find.byType(RaccoonView), findsNWidgets(2));
      expect(connections['counter']!.resizes.last, (
        width: 780,
        height: 1688,
        pixelRatio: 2.0,
      ));
      expect(connections['wonders@tablet']!.resizes.last, (
        width: 1640,
        height: 2360,
        pixelRatio: 2.0,
      ));
      expect(find.text('Raccoon · counter'), findsOneWidget);
      expect(find.text('390 × 844 · 2x ▾'), findsOneWidget);
      expect(find.text('Raccoon Tablet · wonders'), findsOneWidget);
      final first = tester.getTopLeft(find.byType(RaccoonView).first);
      final second = tester.getTopLeft(find.byType(RaccoonView).last);
      expect(second.dx, first.dx + 390 + RaccoonBoardFrame.gap);
      expect(second.dy, first.dy);
    });

    testWidgets('the size chip picks a device size, live and for next time', (
      tester,
    ) async {
      final temp = Directory.systemTemp.createTempSync('raccoon_board');
      addTearDown(() => temp.deleteSync(recursive: true));
      layout = RaccoonBoardLayout(sizes: AppSizes(temp.path));
      final connections = await pumpBoard(tester, ['counter']);

      await tester.tap(find.byKey(RaccoonBoard.sizeKey('counter')));
      await tester.pump();
      expect(
        find.byKey(RaccoonBoard.sizeOptionKey('counter', 'tablet')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(RaccoonBoard.sizeOptionKey('counter', 'tablet')),
      );
      await tester.pump();

      expect(layout.frameFor('counter').size, const Size(820, 1180));
      expect(layout.frameFor('counter').pixelRatio, 2);
      expect(connections['counter']!.resizes.last, (
        width: 1640,
        height: 2360,
        pixelRatio: 2.0,
      ));
      expect(find.text('820 × 1180 · 2x ▾'), findsOneWidget);
      expect(
        find.byKey(RaccoonBoard.sizeOptionKey('counter', 'tablet')),
        findsNothing,
      );
      expect(AppSizes(temp.path).read('counter'), (
        width: 820,
        height: 1180,
        pixelRatio: 2.0,
      ));
    });

    testWidgets('an app run again comes back with its size menu shut', (
      tester,
    ) async {
      await pumpBoard(tester, ['counter']);
      await tester.tap(find.byKey(RaccoonBoard.sizeKey('counter')));
      await tester.pump();
      expect(
        find.byKey(RaccoonBoard.sizeOptionKey('counter', 'tablet')),
        findsOneWidget,
      );
      await pumpBoard(tester, []);
      await pumpBoard(tester, ['counter']);
      expect(
        find.byKey(RaccoonBoard.sizeOptionKey('counter', 'tablet')),
        findsNothing,
      );
    });

    testWidgets('a resize by the handle is kept for next time', (tester) async {
      final temp = Directory.systemTemp.createTempSync('raccoon_board');
      addTearDown(() => temp.deleteSync(recursive: true));
      layout = RaccoonBoardLayout(sizes: AppSizes(temp.path));
      await pumpBoard(tester, ['counter']);
      await tester.drag(
        find.byKey(RaccoonBoard.resizeKey('counter')),
        const Offset(100, 50),
      );
      await tester.pump();
      final size = layout.frameFor('counter').size;
      expect(AppSizes(temp.path).read('counter'), (
        width: size.width.round(),
        height: size.height.round(),
        pixelRatio: 2.0,
      ));
    });

    testWidgets('dragging the title moves the frame', (tester) async {
      await pumpBoard(tester, ['counter']);
      final before = layout.frameFor('counter').position;
      await tester.drag(
        find.byKey(RaccoonBoard.titleKey('counter')),
        const Offset(120, 80),
      );
      await tester.pump();
      expect(
        layout.frameFor('counter').position,
        before + const Offset(120, 80),
      );
      expect(
        tester.getTopLeft(find.byType(RaccoonView)),
        before + const Offset(120, 80),
      );
    });

    testWidgets('the corner handle resizes the frame and the app', (
      tester,
    ) async {
      final connections = await pumpBoard(tester, ['counter']);
      await tester.drag(
        find.byKey(RaccoonBoard.resizeKey('counter')),
        const Offset(50, -44),
      );
      await tester.pump();
      expect(layout.frameFor('counter').size, const Size(440, 800));
      expect(connections['counter']!.resizes.last, (
        width: 880,
        height: 1600,
        pixelRatio: 2.0,
      ));
    });

    testWidgets('holding Alt makes the whole frame a handle', (tester) async {
      final connections = await pumpBoard(tester, ['counter']);
      expect(find.byKey(RaccoonBoard.grabKey('counter')), findsNothing);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(find.byKey(RaccoonBoard.grabKey('counter')), findsOneWidget);

      final before = layout.frameFor('counter').position;
      final pointers = connections['counter']!.pointers.length;
      await tester.drag(
        find.byKey(RaccoonBoard.grabKey('counter')),
        const Offset(-30, 40),
      );
      await tester.pump();
      expect(
        layout.frameFor('counter').position,
        before + const Offset(-30, 40),
      );
      expect(connections['counter']!.pointers.length, pointers);

      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(find.byKey(RaccoonBoard.grabKey('counter')), findsNothing);
    });

    testWidgets('close asks the session to go', (tester) async {
      var closed = 0;
      await pumpBoard(
        tester,
        ['counter'],
        onClose: {'counter': () => closed++},
      );
      await tester.tap(find.byKey(RaccoonBoard.closeKey('counter')));
      expect(closed, 1);
    });

    testWidgets('zoomed out, a frame still follows the pointer', (
      tester,
    ) async {
      await pumpBoard(tester, ['counter']);
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      pointer.hover(const Offset(10, 10));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      for (var i = 0; i < 5; i++) {
        await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      final shown = tester.getRect(find.byType(RaccoonView));
      expect(shown.width, lessThan(390 * 0.7));

      await tester.drag(
        find.byKey(RaccoonBoard.titleKey('counter')),
        const Offset(100, 50),
      );
      await tester.pump();
      final moved = tester.getTopLeft(find.byType(RaccoonView));
      expect(moved.dx, closeTo(shown.left + 100, 0.5));
      expect(moved.dy, closeTo(shown.top + 50, 0.5));

      await tester.drag(
        find.byKey(RaccoonBoard.resizeKey('counter')),
        const Offset(60, 30),
      );
      await tester.pump();
      final grown = tester.getRect(find.byType(RaccoonView));
      expect(grown.width, closeTo(shown.width + 60, 0.5));
      expect(grown.height, closeTo(shown.height + 30, 0.5));
    });

    testWidgets('a frame past the viewport, panned into view, takes drags', (
      tester,
    ) async {
      await pumpBoard(tester, ['counter']);
      layout.move('counter', const Offset(3000, 48));
      await tester.pump();
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      pointer.hover(const Offset(1000, 1000));
      await tester.sendEventToBinding(pointer.scroll(const Offset(1500, 0)));
      await tester.pump();
      final shown = tester.getTopLeft(find.byType(RaccoonView));
      expect(shown.dx, 1500);

      await tester.drag(
        find.byKey(RaccoonBoard.titleKey('counter')),
        const Offset(-100, 20),
      );
      await tester.pump();
      expect(layout.frameFor('counter').position, const Offset(2900, 68));

      await tester.drag(
        find.byKey(RaccoonBoard.resizeKey('counter')),
        const Offset(30, 40),
      );
      await tester.pump();
      expect(layout.frameFor('counter').size, const Size(420, 884));
    });

    testWidgets('a pinch on the empty board zooms about the fingers', (
      tester,
    ) async {
      await pumpBoard(tester, ['counter']);
      final before = tester.getRect(find.byType(RaccoonView));
      final trackpad = TestPointer(1, PointerDeviceKind.trackpad);
      const fingers = Offset(1200, 800);
      await tester.sendEventToBinding(trackpad.panZoomStart(fingers));
      await tester.sendEventToBinding(
        trackpad.panZoomUpdate(fingers, scale: 2),
      );
      await tester.sendEventToBinding(trackpad.panZoomEnd());
      await tester.pump();
      final after = tester.getRect(find.byType(RaccoonView));
      expect(after.width, closeTo(before.width * 2, 0.5));
      // What was under the fingers stays there.
      expect(after.topLeft, fingers + (before.topLeft - fingers) * 2);
      expect(find.text('200%'), findsOneWidget);
    });

    testWidgets('the zoom control steps the zoom and goes back to 100%', (
      tester,
    ) async {
      await pumpBoard(tester, ['counter']);
      final before = tester.getRect(find.byType(RaccoonView));
      expect(find.text('100%'), findsOneWidget);
      await tester.tap(find.text('−'));
      await tester.pump();
      expect(
        tester.getRect(find.byType(RaccoonView)).width,
        closeTo(before.width / 1.25, 0.5),
      );
      expect(find.text('80%'), findsOneWidget);
      await tester.tap(find.text('80%'));
      await tester.pump();
      expect(tester.getRect(find.byType(RaccoonView)), before);
    });

    testWidgets('with Ctrl held, dragging the empty board zooms', (
      tester,
    ) async {
      await pumpBoard(tester, ['counter']);
      final before = tester.getRect(find.byType(RaccoonView));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.dragFrom(const Offset(1600, 1200), const Offset(0, 200));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(
        tester.getRect(find.byType(RaccoonView)).width,
        greaterThan(before.width * 1.1),
      );
    });

    testWidgets('a secondary click asks the host for a menu', (tester) async {
      final asked = <RaccoonBoardMenuRequest>[];
      var closed = false;
      await pumpBoard(
        tester,
        ['counter'],
        onClose: {'counter': () => closed = true},
        onContextMenu: asked.add,
      );
      await tester.tap(
        find.byKey(RaccoonBoard.titleKey('counter')),
        buttons: kSecondaryButton,
      );
      await tester.tapAt(const Offset(2000, 1400), buttons: kSecondaryButton);
      expect(asked.map((request) => request.session), ['counter', null]);
      final frame = asked.first;
      expect(frame.sizes, hasLength(RaccoonDevice.presets.length));
      // A plain name's frame is phone-sized, no preset's size exactly.
      expect(frame.sizes.where((size) => size.current), isEmpty);
      frame.close?.call();
      expect(closed, isTrue);
      final board = asked.last;
      expect(board.sizes, isEmpty);
      expect(board.close, isNull);

      final tablet = frame.sizes.firstWhere(
        (size) => size.label.contains('1024'),
        orElse: () => frame.sizes.last,
      );
      tablet.pick();
      await tester.pump();
      expect(layout.frameFor('counter').size, isNot(const Size(390, 844)));

      board.zoomIn();
      await tester.pump();
      expect(find.text('125%'), findsOneWidget);
      board.resetZoom();
      await tester.pump();
      expect(find.text('100%'), findsOneWidget);
    });

    testWidgets('show all brings every frame into view', (tester) async {
      final asked = <RaccoonBoardMenuRequest>[];
      await pumpBoard(tester, ['a', 'b'], onContextMenu: asked.add);
      layout.move('b', const Offset(6000, 3000));
      await tester.pump();
      await tester.tapAt(const Offset(2000, 1400), buttons: kSecondaryButton);
      asked.single.showAll();
      await tester.pump();
      const screen = Rect.fromLTWH(0, 0, 2400, 1600);
      for (final view in tester.widgetList(find.byType(RaccoonView))) {
        final shown = tester.getRect(find.byWidget(view));
        expect(screen.contains(shown.topLeft), isTrue);
        expect(screen.contains(shown.bottomRight), isTrue);
      }
    });

    testWidgets('scrolling pans the board', (tester) async {
      await pumpBoard(tester, ['counter']);
      final before = tester.getTopLeft(find.byType(RaccoonView));
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      pointer.hover(const Offset(1000, 1000));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
      await tester.pump();
      expect(
        tester.getTopLeft(find.byType(RaccoonView)),
        before - const Offset(0, 100),
      );
    });
  });
}

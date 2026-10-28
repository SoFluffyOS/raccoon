import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raccoon_view/raccoon_view.dart';

void main() {
  testWidgets('the canvas shows the app at its size with a grid and a label', (
    tester,
  ) async {
    await tester.pumpWidget(
      const SizedBox(
        width: 800,
        height: 600,
        child: RaccoonCanvas(
          size: Size(390, 844),
          pixelRatio: 3,
          child: ColoredBox(color: Color(0xFF123456)),
        ),
      ),
    );
    expect(find.text('390 × 844 · 3x'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
    // Scaled down to fit the 600 px height, less the padding, keeping shape.
    final app = tester.getRect(find.byType(ColoredBox));
    expect(app.height, lessThanOrEqualTo(600 - 32));
    expect(app.width / app.height, closeTo(390 / 844, 0.01));
    expect(app.center.dx, closeTo(400, 1));
  });

  Future<void> pumpCanvas(WidgetTester tester) => tester.pumpWidget(
    const Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(
          width: 800,
          height: 600,
          child: RaccoonCanvas(
            size: Size(390, 844),
            pixelRatio: 3,
            child: ColoredBox(color: Color(0xFF123456)),
          ),
        ),
      ),
    ),
  );

  testWidgets('a zoom taken while the pane is collapsed still shows the app '
      'once it grows', (tester) async {
    Future<void> pumpSized(double side) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: side,
            height: side,
            child: const RaccoonCanvas(
              size: Size(390, 844),
              pixelRatio: 3,
              child: ColoredBox(color: Color(0xFF123456)),
            ),
          ),
        ),
      ),
    );
    // Smaller than the canvas's padding: no area at all.
    await pumpSized(20);
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    mouse.hover(tester.getCenter(find.byType(RaccoonCanvas)));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 100)));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await pumpSized(600);
    final app = tester.getRect(find.byType(ColoredBox));
    expect(app.height.isFinite && app.height > 0, isTrue);
    expect(app.left.isFinite && app.top.isFinite, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the zoom control steps the zoom and goes back to fitting', (
    tester,
  ) async {
    await pumpCanvas(tester);
    final fitted = tester.getRect(find.byType(ColoredBox));
    // Fitted to 568 of 844: the percent says so.
    expect(find.text('67%'), findsOneWidget);
    await tester.tap(find.text('+'));
    await tester.pump();
    final zoomed = tester.getRect(find.byType(ColoredBox));
    expect(zoomed.height, closeTo(fitted.height * 1.25, 0.5));
    expect(zoomed.center.dx, closeTo(fitted.center.dx, 0.5));
    expect(find.text('84%'), findsOneWidget);
    await tester.tap(find.text('84%'));
    await tester.pump();
    expect(tester.getRect(find.byType(ColoredBox)), fitted);
  });

  testWidgets('Ctrl and scroll zoom; a pinch around the app zooms', (
    tester,
  ) async {
    await pumpCanvas(tester);
    final fitted = tester.getRect(find.byType(ColoredBox));
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    mouse.hover(fitted.center);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 100)));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    final out = tester.getRect(find.byType(ColoredBox));
    expect(out.height, closeTo(fitted.height / 1.1, 0.5));
    // Zoomed about the pointer: the centre stays put.
    expect(out.center.dx, closeTo(fitted.center.dx, 0.5));

    final trackpad = TestPointer(2, PointerDeviceKind.trackpad);
    final beside = Offset(fitted.left - 60, fitted.center.dy);
    await tester.sendEventToBinding(trackpad.panZoomStart(beside));
    await tester.sendEventToBinding(trackpad.panZoomUpdate(beside, scale: 2));
    await tester.sendEventToBinding(trackpad.panZoomEnd());
    await tester.pump();
    final pinched = tester.getRect(find.byType(ColoredBox));
    expect(pinched.height, greaterThan(out.height * 1.5));
  });

  testWidgets('zoomed past the canvas, dragging around the app pans it', (
    tester,
  ) async {
    await pumpCanvas(tester);
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text('+'));
      await tester.pump();
    }
    final zoomed = tester.getRect(find.byType(ColoredBox));
    expect(zoomed.height, greaterThan(600));
    // Kept covering the area: its top can't come below the padding.
    final canvas = tester.getRect(find.byType(RaccoonCanvas));
    final beside = Offset(zoomed.left - 40, canvas.top + 100);
    await tester.dragFrom(beside, const Offset(0, 120));
    await tester.pump();
    expect(
      tester.getRect(find.byType(ColoredBox)).top,
      closeTo(zoomed.top + 120, 2),
    );
    await tester.dragFrom(beside, const Offset(0, 900));
    await tester.pump();
    expect(
      tester.getRect(find.byType(ColoredBox)).top,
      closeTo(canvas.top + 16, 0.5),
    );
  });

  testWidgets('a fractional ratio and no ratio read right', (tester) async {
    const withHalf = RaccoonCanvas(
      size: Size(100, 50),
      pixelRatio: 2.5,
      child: SizedBox(),
    );
    const without = RaccoonCanvas(size: Size(100, 50), child: SizedBox());
    expect(withHalf.label, '100 × 50 · 2.5x');
    expect(without.label, '100 × 50');
  });
}

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

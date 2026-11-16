// On a Raccoon device, no window needed:
//
//   RACCOON_HEADLESS=1 flutter test integration_test -d raccoon-phone
//   RACCOON_HEADLESS=1 flutter drive -d raccoon-phone \
//     --driver test_driver/integration_test.dart \
//     --target integration_test/app_test.dart

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hello/main.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Color boxColor(WidgetTester tester) => tester
      .widget<ColoredBox>(
        find
            .ancestor(
                of: find.text('Raccoon'), matching: find.byType(ColoredBox))
            .first,
      )
      .color;

  testWidgets('a tap turns the box green, another red again', (tester) async {
    await tester.pumpWidget(const HelloApp());
    expect(boxColor(tester), const Color(0xFFE53935));

    await tester.tap(find.text('Raccoon'));
    await tester.pumpAndSettle();
    expect(boxColor(tester), const Color(0xFF43A047));

    await tester.tap(find.text('Raccoon'));
    await tester.pumpAndSettle();
    expect(boxColor(tester), const Color(0xFFE53935));
  });

  testWidgets('the app fills the device', (tester) async {
    await tester.pumpWidget(const HelloApp());
    final view = tester.view;
    // raccoon-phone is 390 x 844 at 3, raccoon-tablet 820 x 1180 at 2.
    expect(view.physicalSize.isEmpty, isFalse);
    expect(tester.getSize(find.byType(ColoredBox).first),
        view.physicalSize / view.devicePixelRatio);
  });
}

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raccoon_view/raccoon_view.dart';

void main() {
  testWidgets('renders an empty image before the first frame', (tester) async {
    await tester.pumpWidget(const RaccoonFrameView());

    final image = tester.widget<RawImage>(find.byType(RawImage));
    expect(image.image, isNull);
    expect(image.fit, BoxFit.contain);
  });
}

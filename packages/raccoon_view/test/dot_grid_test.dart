import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:raccoon_view/src/dot_grid.dart';

void main() {
  // #112: one call for the whole grid, not one per dot.
  test('draws every dot of the lattice in one call', () {
    final canvas = TestRecordingCanvas();
    paintDotGrid(
      canvas,
      const Size(100, 50),
      const Offset(50, 25),
      24,
      const Color(0xFF808080),
    );

    expect(canvas.invocations, hasLength(1));
    final call = canvas.invocations.single.invocation;
    expect(call.memberName, #drawRawPoints);
    expect(call.positionalArguments[0], PointMode.points);
    final points = call.positionalArguments[1] as Float32List;
    // x from 50 % 24 = 2, y from 25 % 24 = 1: 5 columns, 3 rows.
    expect(points, hasLength(5 * 3 * 2));
    expect(points.sublist(0, 2), [2, 1]);
    expect(points.sublist(points.length - 2), [98, 49]);
    final paint = call.positionalArguments[2] as Paint;
    expect(paint.strokeWidth, 2);
    expect(paint.strokeCap, StrokeCap.round);
    expect(paint.color.toARGB32(), 0xFF808080);
  });

  test('draws nothing where no dot fits', () {
    final canvas = TestRecordingCanvas();
    paintDotGrid(
      canvas,
      Size.zero,
      const Offset(5, 5),
      24,
      const Color(0xFF808080),
    );
    expect(canvas.invocations, isEmpty);
  });
}

import 'dart:typed_data';
import 'dart:ui';

/// Dots [step] apart over [size], on a lattice through [origin]: round
/// points two pixels wide, the size of a circle of radius one, all drawn in
/// one call. A grid of circles took a call per dot, up to 10 ms of a frame
/// on a zoomed-out board (#112).
void paintDotGrid(
  Canvas canvas,
  Size size,
  Offset origin,
  double step,
  Color color,
) {
  final startX = origin.dx % step;
  final startY = origin.dy % step;
  if (startX > size.width || startY > size.height) return;
  final columns = ((size.width - startX) / step).floor() + 1;
  final rows = ((size.height - startY) / step).floor() + 1;
  final points = Float32List(columns * rows * 2);
  var i = 0;
  for (var column = 0; column < columns; column++) {
    final x = startX + column * step;
    for (var row = 0; row < rows; row++) {
      points[i++] = x;
      points[i++] = startY + row * step;
    }
  }
  canvas.drawRawPoints(
    PointMode.points,
    points,
    Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round,
  );
}

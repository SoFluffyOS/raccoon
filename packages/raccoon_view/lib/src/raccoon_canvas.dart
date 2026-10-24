import 'package:flutter/widgets.dart';
import 'package:raccoon_view/src/dot_grid.dart';

/// A hosted app at a fixed logical size, on a canvas: a quiet dot grid
/// behind it, a one-pixel edge around it, and its size in a corner, so the
/// space around a phone-sized app reads as a drawing board rather than
/// nothing. The app is scaled down to fit when the canvas is smaller.
///
/// Only for fixed sizes; an app that fills its box needs no canvas. Hosts
/// pass their own ink colour and label style; the defaults are a grey that
/// sits on dark and light backgrounds alike.
class RaccoonCanvas extends StatelessWidget {
  const RaccoonCanvas({
    super.key,
    required this.size,
    required this.child,
    this.pixelRatio,
    this.ink = const Color(0xFF808080),
    this.labelStyle,
    this.spacing = 24,
    this.padding = const EdgeInsets.all(16),
  });

  /// The app's logical size.
  final Size size;

  /// The device pixel ratio the app is shown at, for the label.
  final double? pixelRatio;

  /// The hosted app, laid out at [size].
  final Widget child;

  /// The colour of the dots, the edge and the label, at their own
  /// strengths.
  final Color ink;

  /// The label's style; the colour comes from [ink] unless given.
  final TextStyle? labelStyle;

  /// Distance between dots, in the canvas's pixels.
  final double spacing;

  /// Space between the canvas's edge and the app; the label sits in its
  /// bottom right.
  final EdgeInsets padding;

  /// What the label says: `390 × 844 · 3x`.
  String get label {
    final dims = '${size.width.round()} × ${size.height.round()}';
    return switch (pixelRatio) {
      null => dims,
      final ratio => '$dims · ${_ratioLabel(ratio)}x',
    };
  }

  static String _ratioLabel(double ratio) => switch (ratio ==
      ratio.roundToDouble()) {
    true => '${ratio.round()}',
    false => '$ratio',
  };

  @override
  Widget build(BuildContext context) {
    final style = (labelStyle ?? const TextStyle(fontSize: 11)).copyWith(
      color: labelStyle?.color ?? ink.withValues(alpha: 0.7),
    );
    return CustomPaint(
      painter: _DotGridPainter(
        ink: ink.withValues(alpha: 0.28),
        spacing: spacing,
      ),
      child: Stack(
        alignment: Alignment.topLeft,
        fit: StackFit.expand,
        children: [
          Padding(
            padding: padding,
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(
                    border: Border.all(color: ink.withValues(alpha: 0.55)),
                  ),
                  child: SizedBox(
                    width: size.width,
                    height: size.height,
                    child: child,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: padding.right,
            bottom: padding.bottom / 2,
            child: Text(label, style: style, textDirection: TextDirection.ltr),
          ),
        ],
      ),
    );
  }
}

class _DotGridPainter extends CustomPainter {
  const _DotGridPainter({required this.ink, required this.spacing});

  final Color ink;
  final double spacing;

  @override
  void paint(Canvas canvas, Size size) {
    // Dots on a lattice anchored at the centre, so the grid stays put
    // around the app when the canvas is resized.
    paintDotGrid(canvas, size, size.center(Offset.zero), spacing, ink);
  }

  @override
  bool shouldRepaint(_DotGridPainter old) =>
      old.ink != ink || old.spacing != spacing;
}

import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// How far the board and the canvas zoom out and in.
const minZoom = 0.25;
const maxZoom = 3.0;

/// One step of the zoom control's buttons.
const zoomStep = 1.25;

/// Whether Ctrl or Cmd is held: a scroll or a drag then zooms rather than
/// pans.
bool zoomModifierHeld() =>
    HardwareKeyboard.instance.isControlPressed ||
    HardwareKeyboard.instance.isMetaPressed;

/// Around what a board or a canvas shows: a scroll there with
/// [zoomModifierHeld] zooms them, and a view inside leaves it to them
/// rather than scroll its app too (#233).
class ZoomsOnModifiedScroll extends InheritedWidget {
  const ZoomsOnModifiedScroll({super.key, required super.child});

  /// Whether [context] sits inside one.
  static bool around(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ZoomsOnModifiedScroll>() != null;

  @override
  bool updateShouldNotify(ZoomsOnModifiedScroll oldWidget) => false;
}

/// How much a scroll or drag of [dy] logical pixels with the modifier held
/// zooms by: a wheel's notch of 100 is the old step of 1.1, and a
/// trackpad's smaller steps add up to the same.
double zoomFactorForScroll(double dy) => math.pow(1.1, -dy / 100).toDouble();

/// What a view at [zoom], drawn from [origin], is moved to when zoomed to
/// [next] about [focus], so the point under [focus] stays put.
Offset zoomAbout(Offset origin, double zoom, double next, Offset focus) =>
    focus - (focus - origin) * (next / zoom);

/// The zoom in a corner: a minus, the zoom in percent, a plus. The percent
/// goes back to where the view started.
class ZoomControl extends StatelessWidget {
  const ZoomControl({
    super.key,
    required this.zoom,
    required this.onZoomOut,
    required this.onZoomIn,
    required this.onReset,
    required this.style,
  });

  final double zoom;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomIn;
  final VoidCallback onReset;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      textDirection: TextDirection.ltr,
      children: [
        _button('−', onZoomOut, enabled: zoom > minZoom),
        _button('${(zoom * 100).round()}%', onReset, enabled: true),
        _button('+', onZoomIn, enabled: zoom < maxZoom),
      ],
    );
  }

  Widget _button(String text, VoidCallback onTap, {required bool enabled}) {
    final label = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Text(
        text,
        style: switch (enabled) {
          true => style,
          false => style.copyWith(
            color: style.color?.withValues(alpha: (style.color?.a ?? 1) / 2),
          ),
        },
        textDirection: TextDirection.ltr,
      ),
    );
    if (!enabled) return label;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: label,
      ),
    );
  }
}

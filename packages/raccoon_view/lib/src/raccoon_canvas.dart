import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:raccoon_view/src/dot_grid.dart';
import 'package:raccoon_view/src/zoom_control.dart';

/// A hosted app at a fixed logical size, on a canvas: a quiet dot grid
/// behind it, a one-pixel edge around it, and its size in a corner, so the
/// space around a phone-sized app reads as a drawing board rather than
/// nothing. The app is scaled down to fit when the canvas is smaller.
///
/// It zooms too: pinch the canvas around the app, or hold Ctrl (or Cmd) and
/// scroll or drag; the zoom control in the bottom left steps it, and its
/// percent goes back to fitting. Zoomed past the canvas, dragging or
/// scrolling the canvas around the app pans it.
///
/// Only for fixed sizes; an app that fills its box needs no canvas. Hosts
/// pass their own ink colour and label style; the defaults are a grey that
/// sits on dark and light backgrounds alike.
class RaccoonCanvas extends StatefulWidget {
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
  State<RaccoonCanvas> createState() => _RaccoonCanvasState();
}

class _RaccoonCanvasState extends State<RaccoonCanvas> {
  /// The zoom picked, or null to fit the app to the canvas.
  double? _zoom;

  /// Where the app's top left sits in the area inside the padding, once it
  /// is larger than that area; it is centred while it fits.
  Offset _origin = Offset.zero;

  double _zoomAtStart = 1;

  /// The area inside the padding and the zoom that fits the app to it, as
  /// last laid out.
  Size _area = Size.zero;
  double _fit = 1;

  double get _scale => _zoom ?? _fit;

  /// Where the app sits in [area] at [scale] with [origin] asked for:
  /// centred along an axis it fits, kept covering the area along one it
  /// overflows.
  Offset _placed(Size area, double scale, Offset origin) {
    double along(double room, double length, double asked) => switch (length <=
        room) {
      true => (room - length) / 2,
      false => asked.clamp(room - length, 0.0),
    };
    return Offset(
      along(area.width, widget.size.width * scale, origin.dx),
      along(area.height, widget.size.height * scale, origin.dy),
    );
  }

  /// Zooms to [next] about [focus], a point in the canvas, so what is under
  /// it stays put.
  void _zoomTo(double next, Offset focus) {
    final scale = _scale;
    // An app that fits only below the least zoom zooms out no further than
    // that fit, rather than jump in to it (#233).
    final zoom = next.clamp(math.min(minZoom, _fit), maxZoom).toDouble();
    final inArea = focus - widget.padding.topLeft;
    final placed = _placed(_area, scale, _origin);
    setState(() {
      _origin = _placed(_area, zoom, zoomAbout(placed, scale, zoom, inArea));
      _zoom = zoom;
    });
  }

  void _panBy(Offset delta) {
    setState(() => _origin = _placed(_area, _scale, _origin) + delta);
  }

  void _onScroll(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (zoomModifierHeld()) {
      _zoomTo(
        _scale * zoomFactorForScroll(event.scrollDelta.dy),
        event.localPosition,
      );
      return;
    }
    // Over the app the scroll is the app's; around it, it pans.
    if (_appRect().contains(event.localPosition)) return;
    _panBy(-event.scrollDelta);
  }

  Rect _appRect() =>
      (widget.padding.topLeft + _placed(_area, _scale, _origin)) &
      (widget.size * _scale);

  void _onScaleStart(ScaleStartDetails details) => _zoomAtStart = _scale;

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (details.scale != 1) {
      _zoomTo(_zoomAtStart * details.scale, details.localFocalPoint);
      return;
    }
    if (zoomModifierHeld()) {
      _zoomTo(
        _scale * zoomFactorForScroll(-details.focalPointDelta.dy),
        details.localFocalPoint,
      );
      return;
    }
    _panBy(details.focalPointDelta);
  }

  void _step(double factor) {
    _zoomTo(
      _scale * factor,
      widget.padding.topLeft + _area.center(Offset.zero),
    );
  }

  @override
  Widget build(BuildContext context) {
    final widget = this.widget;
    final style = (widget.labelStyle ?? const TextStyle(fontSize: 11)).copyWith(
      color: widget.labelStyle?.color ?? widget.ink.withValues(alpha: 0.7),
    );
    return ZoomsOnModifiedScroll(
      child: Listener(
        onPointerSignal: _onScroll,
        child: CustomPaint(
          painter: _DotGridPainter(
            ink: widget.ink.withValues(alpha: 0.28),
            spacing: widget.spacing,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              _area = widget.padding.deflateSize(constraints.biggest);
              _fit = math.min(
                1,
                math.min(
                  _area.width / widget.size.width,
                  _area.height / widget.size.height,
                ),
              );
              final scale = _scale;
              final placed = _placed(_area, scale, _origin);
              return Stack(
                alignment: Alignment.topLeft,
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onScaleStart: _onScaleStart,
                      onScaleUpdate: _onScaleUpdate,
                    ),
                  ),
                  Positioned(
                    left: widget.padding.left + placed.dx,
                    top: widget.padding.top + placed.dy,
                    width: widget.size.width * scale,
                    height: widget.size.height * scale,
                    child: FittedBox(
                      fit: BoxFit.fill,
                      child: DecoratedBox(
                        position: DecorationPosition.foreground,
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: widget.ink.withValues(alpha: 0.55),
                          ),
                        ),
                        child: SizedBox(
                          width: widget.size.width,
                          height: widget.size.height,
                          child: widget.child,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: widget.padding.left,
                    bottom: widget.padding.bottom / 2 - 2,
                    child: ZoomControl(
                      zoom: scale,
                      style: style,
                      onZoomOut: () => _step(1 / zoomStep),
                      onZoomIn: () => _step(zoomStep),
                      onReset: () => setState(() => _zoom = null),
                    ),
                  ),
                  Positioned(
                    right: widget.padding.right,
                    bottom: widget.padding.bottom / 2,
                    child: Text(
                      widget.label,
                      style: style,
                      textDirection: TextDirection.ltr,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
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

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Shows the latest frame a runner sent, or nothing before the first one.
class RaccoonFrameView extends StatelessWidget {
  const RaccoonFrameView({super.key, this.frame, this.fit = BoxFit.contain});

  /// The decoded frame; null shows nothing.
  final ui.Image? frame;

  /// How the frame fills the view.
  final BoxFit fit;

  @override
  Widget build(BuildContext context) => RawImage(image: frame, fit: fit);
}

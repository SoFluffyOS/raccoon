import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Shows the latest frame a runner sent, or nothing before the first one.
class RaccoonFrameView extends StatelessWidget {
  const RaccoonFrameView({super.key, this.frame, this.fit = BoxFit.contain});

  final ui.Image? frame;

  final BoxFit fit;

  @override
  Widget build(BuildContext context) => RawImage(image: frame, fit: fit);
}

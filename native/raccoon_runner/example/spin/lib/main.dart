import 'dart:math' as math;

import 'package:flutter/widgets.dart';

void main() => runApp(const SpinApp());

/// A box turning once per second over a gradient, so every frame differs.
class SpinApp extends StatefulWidget {
  const SpinApp({super.key});

  @override
  State<SpinApp> createState() => _SpinAppState();
}

class _SpinAppState extends State<SpinApp> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF1E88E5), Color(0xFF8E24AA)],
          ),
        ),
        child: Center(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) => Transform.rotate(
              angle: _controller.value * 2 * math.pi,
              child: child,
            ),
            child: const SizedBox(
              width: 240,
              height: 240,
              child: ColoredBox(
                color: Color(0xFFE53935),
                child: Center(
                  child: Text(
                    'spin',
                    style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 48),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

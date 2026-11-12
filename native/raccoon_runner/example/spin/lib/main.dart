import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Draws in every view the runner gives the app, so a views run (#182)
/// animates each of them; a normal run has the one.
void main() {
  _EveryViewBinding();
  runApp(const SpinApp());
}

class _EveryViewBinding extends WidgetsFlutterBinding {
  @override
  Widget wrapWithDefaultView(Widget rootWidget) =>
      _EveryView(child: rootWidget);
}

class _EveryView extends StatefulWidget {
  const _EveryView({required this.child});

  final Widget child;

  @override
  State<_EveryView> createState() => _EveryViewState();
}

class _EveryViewState extends State<_EveryView> with WidgetsBindingObserver {
  late List<int> _ids = _viewIds();

  static List<int> _viewIds() => [
    for (final view in WidgetsBinding.instance.platformDispatcher.views)
      view.viewId,
  ]..sort();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Views come and go with the metrics.
  @override
  void didChangeMetrics() {
    final ids = _viewIds();
    if (ids.length == _ids.length &&
        ids.indexed.every((e) => e.$2 == _ids[e.$1])) {
      return;
    }
    setState(() => _ids = ids);
  }

  @override
  Widget build(BuildContext context) {
    final dispatcher = WidgetsBinding.instance.platformDispatcher;
    return ViewCollection(
      views: [
        for (final id in _ids)
          if (dispatcher.view(id: id) case final view?)
            View(key: ValueKey(id), view: view, child: widget.child),
      ],
    );
  }
}

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

import 'package:flutter/widgets.dart';

/// Installs the binding a views run's entry point installs, then runs the
/// app as its own main would.
void main() {
  RaccoonViewsBinding();
  runApp(const ViewsApp());
}

/// Draws the root widget in every view the runner gives the app, each its
/// own instance; `runApp` alone draws only in the first.
class RaccoonViewsBinding extends WidgetsFlutterBinding {
  @override
  Widget wrapWithDefaultView(Widget rootWidget) =>
      _RaccoonViews(child: rootWidget);
}

class _RaccoonViews extends StatefulWidget {
  const _RaccoonViews({required this.child});

  final Widget child;

  @override
  State<_RaccoonViews> createState() => _RaccoonViewsState();
}

class _RaccoonViewsState extends State<_RaccoonViews>
    with WidgetsBindingObserver {
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
    if (ids.length == _ids.length && ids.indexed.every((e) => e.$2 == _ids[e.$1])) {
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

/// Fills each view with its own colour (view 0 blue, 1 green, 2 orange),
/// with a box in the middle that toggles red and white on a tap: a test
/// reads which view drew what, and that a tap reached only its own view.
class ViewsApp extends StatefulWidget {
  const ViewsApp({super.key});

  @override
  State<ViewsApp> createState() => _ViewsAppState();
}

class _ViewsAppState extends State<ViewsApp> {
  static const _backgrounds = [
    Color(0xFF1E88E5),
    Color(0xFF43A047),
    Color(0xFFFB8C00),
  ];
  static const _red = Color(0xFFE53935);
  static const _white = Color(0xFFFFFFFF);

  var _box = _red;

  @override
  Widget build(BuildContext context) {
    final view = View.of(context);
    final size = MediaQuery.sizeOf(context);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: _backgrounds[view.viewId % _backgrounds.length],
        child: Center(
          child: GestureDetector(
            onTap: () => setState(() => _box = _box == _red ? _white : _red),
            child: SizedBox(
              width: 120,
              height: 80,
              child: ColoredBox(
                color: _box,
                child: Center(
                  child: Text(
                    '${view.viewId}: ${size.width.round()}x${size.height.round()}',
                    style: const TextStyle(color: Color(0xFF000000)),
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

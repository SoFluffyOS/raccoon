import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The channel of a plugin nobody serves, named the way a method channel
/// plugin names one.
const channel = MethodChannel('plugins.flutter.io/absent_plugin');

void main() => runApp(const LateApp());

/// Draws its first frame, then calls a plugin nobody serves, the way an app
/// does from a screen it already shows, and again on every tap of the box.
/// A blue background with a box in the middle: grey while a call is out,
/// orange once it failed with MissingPluginException, green if anything
/// answered. Prints NO_PLUGIN_LATE: with what came back and how long it
/// took.
class LateApp extends StatefulWidget {
  const LateApp({super.key});

  @override
  State<LateApp> createState() => _LateAppState();
}

class _LateAppState extends State<LateApp> {
  static const _grey = Color(0xFF9E9E9E);
  static const _orange = Color(0xFFFB8C00);
  static const _green = Color(0xFF43A047);

  var _boxColor = _grey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _call());
  }

  Future<void> _call() async {
    setState(() => _boxColor = _grey);
    final watch = Stopwatch()..start();
    try {
      final reply = await channel.invokeMethod<Object?>('initialize');
      // ignore: avoid_print
      print('NO_PLUGIN_LATE:$reply after ${watch.elapsedMilliseconds} ms');
      setState(() => _boxColor = _green);
    } on MissingPluginException catch (error) {
      // ignore: avoid_print
      print(
        'NO_PLUGIN_LATE:${error.runtimeType} after '
        '${watch.elapsedMilliseconds} ms',
      );
      setState(() => _boxColor = _orange);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF1E88E5),
      child: Center(
        child: GestureDetector(
          onTap: _call,
          child: SizedBox(
            width: 240,
            height: 120,
            child: ColoredBox(color: _boxColor),
          ),
        ),
      ),
    );
  }
}

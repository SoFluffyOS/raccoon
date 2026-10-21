import 'package:flutter/widgets.dart';

void main() => runApp(const HelloApp());

/// Blue background, a box in the middle, white text. The box starts red and
/// turns green on every tap, so a test can verify input end to end from the
/// pixels of the next frame.
class HelloApp extends StatefulWidget {
  const HelloApp({super.key});

  @override
  State<HelloApp> createState() => _HelloAppState();
}

class _HelloAppState extends State<HelloApp> {
  static const _red = Color(0xFFE53935);
  static const _green = Color(0xFF43A047);

  var _boxColor = _red;

  void _toggle() {
    setState(() {
      _boxColor = switch (_boxColor) { _red => _green, _ => _red };
    });
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xFF1E88E5),
        child: Center(
          child: GestureDetector(
            onTap: _toggle,
            child: SizedBox(
              width: 240,
              height: 120,
              child: ColoredBox(
                color: _boxColor,
                child: const Center(
                  child: Text(
                    'Raccoon',
                    style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 36),
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

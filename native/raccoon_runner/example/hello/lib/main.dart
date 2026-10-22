import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

void main() => runApp(const HelloApp());

/// Blue background, a box in the middle, white text. The box starts red and
/// toggles to green on every tap, so a test can verify input end to end from
/// the pixels of the next frame. A tap also reads the clipboard: when it holds
/// the word "raccoon" the box turns purple instead, which proves a platform
/// message went out to the client and its answer came back.
class HelloApp extends StatefulWidget {
  const HelloApp({super.key});

  @override
  State<HelloApp> createState() => _HelloAppState();
}

class _HelloAppState extends State<HelloApp> {
  static const _red = Color(0xFFE53935);
  static const _green = Color(0xFF43A047);
  static const _purple = Color(0xFF8E24AA);

  var _boxColor = _red;

  Future<void> _toggle() async {
    setState(() {
      _boxColor = switch (_boxColor) { _red => _green, _ => _red };
    });
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || clipboard?.text != 'raccoon') return;
    setState(() => _boxColor = _purple);
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

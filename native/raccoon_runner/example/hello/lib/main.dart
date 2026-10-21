import 'package:flutter/widgets.dart';

void main() => runApp(const HelloApp());

/// Blue background, a red box in the middle, white text: three colours whose
/// pixel values the runner's first test can check.
class HelloApp extends StatelessWidget {
  const HelloApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: Color(0xFF1E88E5),
        child: Center(
          child: SizedBox(
            width: 240,
            height: 120,
            child: ColoredBox(
              color: Color(0xFFE53935),
              child: Center(
                child: Text(
                  'Raccoon',
                  style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 36),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

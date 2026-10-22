import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

void main() => runApp(const TextApp());

/// A focused text field, for testing text input end to end. Every change
/// prints `TEXT:<value>`; every key event the framework dispatches prints
/// `KEY:<type>:<label>`, so a probe can tell key delivery from text entry.
class TextApp extends StatefulWidget {
  const TextApp({super.key});

  @override
  State<TextApp> createState() => _TextAppState();
}

class _TextAppState extends State<TextApp> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    debugPrint('KEY:${event.runtimeType}:${event.logicalKey.keyLabel}');
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xFF1E88E5),
        child: Center(
          child: SizedBox(
            width: 400,
            child: ColoredBox(
              color: const Color(0xFFFFFFFF),
              child: EditableText(
                controller: _controller,
                focusNode: _focus,
                autofocus: true,
                style: const TextStyle(color: Color(0xFF000000), fontSize: 32),
                cursorColor: const Color(0xFF000000),
                backgroundCursorColor: const Color(0xFF888888),
                onChanged: (value) => debugPrint('TEXT:$value'),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

void main() => runApp(const TextApp());

/// A focused text field, for testing text input end to end. Every change
/// prints `TEXT:<value>`; every key event the framework dispatches prints
/// `KEY:<type>:<label>`, so a probe can tell key delivery from text entry.
/// The deprecated RawKeyboard's events print `RAW:<type>:<physical key>:
/// <keys it holds pressed>:<shift>:<control>`, physical keys as USB HID
/// usages in hex.
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
    // ignore: deprecated_member_use
    RawKeyboard.instance.addListener(_onRawKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    // ignore: deprecated_member_use
    RawKeyboard.instance.removeListener(_onRawKey);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    debugPrint('KEY:${event.runtimeType}:${event.logicalKey.keyLabel}');
    return false;
  }

  // ignore: deprecated_member_use
  void _onRawKey(RawKeyEvent event) {
    String hex(PhysicalKeyboardKey key) => key.usbHidUsage.toRadixString(16);
    // ignore: deprecated_member_use
    final pressed = RawKeyboard.instance.physicalKeysPressed.map(hex).toList()
      ..sort();
    debugPrint(
      'RAW:${event.runtimeType}:${hex(event.physicalKey)}:${pressed.join(',')}'
      // ignore: deprecated_member_use
      ':${event.isShiftPressed}:${event.isControlPressed}',
    );
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

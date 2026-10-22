import 'package:flutter/widgets.dart';
import 'package:raccoon_echo/raccoon_echo.dart';

/// Calls the native plugin before the first frame and prints what came
/// back as ECHO:<answer>; green when the plugin answered, red otherwise.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String line;
  try {
    line = 'ECHO:${await RaccoonEcho.echo('hello')}';
  } catch (error) {
    line = 'ECHO:error $error';
  }
  // ignore: avoid_print
  print(line);
  runApp(
    ColoredBox(
      color: line == 'ECHO:echo: hello'
          ? const Color(0xFF2E7D32)
          : const Color(0xFFC62828),
    ),
  );
}

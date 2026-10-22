import 'package:flutter/widgets.dart';
import 'package:raccoon_echo/raccoon_echo.dart';

/// Calls the native plugin before the first frame and prints what came
/// back: ECHO:<answer>, then TEXTURE:<id>. With a texture it draws that full
/// screen, orange; otherwise green when the plugin answered, red otherwise.
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
  int? textureId;
  try {
    textureId = await RaccoonEcho.texture();
    // ignore: avoid_print
    print('TEXTURE:$textureId');
  } catch (error) {
    // ignore: avoid_print
    print('TEXTURE:error $error');
  }
  runApp(
    switch (textureId) {
      final id? => Texture(textureId: id),
      null => ColoredBox(
        color: line == 'ECHO:echo: hello'
            ? const Color(0xFF2E7D32)
            : const Color(0xFFC62828),
      ),
    },
  );
}

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:raccoon_echo/raccoon_echo.dart';

/// Calls the native plugin before the first frame and prints what came
/// back: ECHO:<answer>, APARTMENT:<COM apartment> (Windows),
/// SECURE:<options> (macOS), then TEXTURE:<id>. With a
/// texture it draws that full screen, orange; otherwise green when the
/// plugin answered, red otherwise. Told `untexture` on `raccoon_echo_app`
/// (a client's app message), it lets the texture go and prints
/// UNTEXTURE:<where the host said so>.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const BasicMessageChannel<String>(
    'raccoon_echo_app',
    StringCodec(),
  ).setMessageHandler((message) async {
    if (message != 'untexture') return '';
    try {
      // ignore: avoid_print
      print('UNTEXTURE:${await RaccoonEcho.untexture()}');
    } catch (error) {
      // ignore: avoid_print
      print('UNTEXTURE:error $error');
    }
    return '';
  });
  String line;
  try {
    line = 'ECHO:${await RaccoonEcho.echo('hello')}';
  } catch (error) {
    line = 'ECHO:error $error';
  }
  // ignore: avoid_print
  print(line);
  try {
    // ignore: avoid_print
    print('APARTMENT:${await RaccoonEcho.apartment()}');
  } catch (error) {
    // ignore: avoid_print
    print('APARTMENT:error $error');
  }
  try {
    final options = await RaccoonEcho.secureStorageOptions({
      'accountName': 'app',
      'groupId': 'team.group',
      'synchronizable': 'true',
      'usesDataProtectionKeychain': 'true',
    });
    // ignore: avoid_print
    print('SECURE:$options');
  } catch (error) {
    // ignore: avoid_print
    print('SECURE:error $error');
  }
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

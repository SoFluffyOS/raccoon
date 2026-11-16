import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:raccoon_echo/raccoon_echo.dart';

/// Calls the native plugin before the first frame and prints what came
/// back: ECHO:<answer>, APARTMENT:<COM apartment> (Windows),
/// SECURE:<options> (macOS), then TEXTURE:<id>. With a
/// texture it draws that full screen, orange; otherwise green when the
/// plugin answered, red otherwise. Told `untexture` on `raccoon_echo_app`
/// (a client's app message), it lets the texture go and prints
/// UNTEXTURE:<where the host said so>. Told `churn:<n>`, it draws n
/// textures in turn that the plugin lets go while their frames draw, then
/// prints CHURN:<what became of them> (#123).
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const BasicMessageChannel<String>(
    'raccoon_echo_app',
    StringCodec(),
  ).setMessageHandler((message) async {
    if (message != null && message.startsWith('churn:')) {
      await _churn(int.tryParse(message.substring(6)) ?? 1);
      return '';
    }
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
  _shown.value = textureId;
  final color = line == 'ECHO:echo: hello'
      ? const Color(0xFF2E7D32)
      : const Color(0xFFC62828);
  runApp(
    ValueListenableBuilder<int?>(
      valueListenable: _shown,
      builder: (context, id, _) => switch (id) {
        final id? => Texture(textureId: id),
        null => ColoredBox(color: color),
      },
    ),
  );
}

/// Whether every churned texture of [report] has been finalized.
bool _settled(String report) {
  int? count(String key) =>
      int.tryParse(RegExp('$key=(\\d+)').firstMatch(report)?.group(1) ?? '');
  final made = count('made');
  return made != null && count('finalized') == made;
}

/// The texture drawn full screen, if any.
final _shown = ValueNotifier<int?>(null);

Future<void> _churn(int count) async {
  final before = _shown.value;
  String report;
  try {
    for (var i = 0; i < count; i++) {
      _shown.value = await RaccoonEcho.churn();
      await RaccoonEcho.churned();
    }
    _shown.value = before;
    // The last one goes once its frame is done with it.
    final until = DateTime.now().add(const Duration(seconds: 2));
    do {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      report = await RaccoonEcho.churnReport() ?? '';
    } while (!_settled(report) && DateTime.now().isBefore(until));
  } catch (error) {
    report = 'error $error';
  }
  // ignore: avoid_print
  print('CHURN:$report');
}

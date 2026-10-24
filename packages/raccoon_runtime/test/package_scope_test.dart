import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final script = p.normalize(
    p.join(
      Directory.current.path,
      '..',
      '..',
      'native',
      'raccoon_runner',
      'tool',
      'package_scope.dart',
    ),
  );
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('raccoon_scope'));
  tearDown(() => temp.deleteSync(recursive: true));

  void config(String folder, List<String> names) {
    File(p.join(folder, '.dart_tool', 'package_config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            for (final name in names)
              {
                'name': name,
                'rootUri': '../packages/$name',
                'packageUri': 'lib/',
              },
          ],
        }),
      );
  }

  // #141: a config left in a folder between the member and the root, from
  // before the move to a workspace, was taken for the root's, and the app
  // got no plugins.
  for (final withRef in [true, false]) {
    test('a member finds the root past a stale config, '
        '${withRef ? 'by its workspace ref' : 'by searching up'}', () async {
      final root = p.join(temp.path, 'root');
      final app = p.join(root, 'packages', 'app');
      Directory(app).createSync(recursive: true);
      config(root, ['app']);
      // A stale one, between: it names another app.
      config(p.join(root, 'packages'), ['old']);
      if (withRef) {
        File(p.join(app, '.dart_tool', 'pub', 'workspace_ref.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync(jsonEncode({'workspaceRoot': '../../../..'}));
      }
      final out = p.join(app, 'build', 'raccoon', 'package_config.json');
      final result = await Process.run(Platform.resolvedExecutable, [
        script,
        app,
        out,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final names = [
        for (final package
            in (jsonDecode(File(out).readAsStringSync()) as Map)['packages']
                as List)
          (package as Map)['name'],
      ];
      expect(names, ['app']);
    });
  }
}

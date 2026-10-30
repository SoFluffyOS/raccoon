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
  // As raccoon-device runs it: with a package config of none (#217).
  final noPackages =
      '--packages=${p.join(p.dirname(script), 'no_packages.json')}';
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
        noPackages,
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

  test(
    'runs inside a workspace that asks for a newer Dart than the SDK',
    () async {
      // #217: a checkout inside a pub workspace whose root asks for a newer
      // language version than this SDK has; dart would take that config.
      final tool = Directory(p.join(temp.path, 'workspace', 'tool'))
        ..createSync(recursive: true);
      final copy = File(
        script,
      ).copySync(p.join(tool.path, 'package_scope.dart'));
      File(p.join(temp.path, 'workspace', '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'configVersion': 2,
            'packages': [
              {
                'name': 'workspace',
                'rootUri': '../',
                'packageUri': 'lib/',
                'languageVersion': '99.0',
              },
            ],
          }),
        );
      final plain = await Process.run(Platform.resolvedExecutable, [copy.path]);
      expect('${plain.stderr}', contains('too high'));
      final scoped = await Process.run(Platform.resolvedExecutable, [
        noPackages,
        copy.path,
      ]);
      // Its usage: it ran.
      expect(scoped.exitCode, 2, reason: '${scoped.stderr}');
      expect('${scoped.stderr}', contains('usage: package_scope.dart'));
    },
  );

  // #310: a config or graph that can't be read threw out of the search.
  test('a config that can\'t be read is passed, and a graph that can\'t '
      'is none', () async {
    final root = p.join(temp.path, 'root');
    final app = p.join(root, 'packages', 'app');
    Directory(app).createSync(recursive: true);
    config(root, ['app', 'dep']);
    File(
      p.join(root, '.dart_tool', 'package_graph.json'),
    ).writeAsBytesSync([0xff, 0xfe]);
    File(p.join(root, 'packages', '.dart_tool', 'package_config.json'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([0xff, 0xfe, 0x7b]);
    final out = p.join(app, 'build', 'raccoon', 'package_config.json');
    final result = await Process.run(Platform.resolvedExecutable, [
      noPackages,
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
    expect(names, ['app', 'dep']);
  });

  // The Windows plugin builder reads the config before anything of
  // Windows': one that isn't a config is said, on any host (#310).
  test(
    'the Windows plugin builder says so of a config that is not one',
    () async {
      final builder = p.join(p.dirname(script), 'plugins_windows.dart');
      final file = File(p.join(temp.path, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true);
      for (final bytes in [
        '{oops'.codeUnits,
        '[1]'.codeUnits,
        [0xff, 0xfe],
      ]) {
        file.writeAsBytesSync(bytes);
        final result = await Process.run(Platform.resolvedExecutable, [
          noPackages,
          builder,
          file.path,
          p.join(temp.path, 'out'),
          '',
          p.join(temp.path, 'cache'),
          '0.3.0',
          p.join(temp.path, 'engine'),
        ]);
        expect(result.exitCode, 1, reason: '$bytes');
        expect('${result.stderr}', contains('is not a package config'));
        expect('${result.stderr}', isNot(contains('#0')));
      }
    },
  );
}

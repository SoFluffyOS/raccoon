// raccoon-device's install of native assets, on a project whose hook package
// a stand-in Flutter SDK "builds": its flutter assemble writes the manifest
// each case gives and a code asset where the real one puts it. Native assets
// are built on macOS and Linux only.
@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _fakeFlutter = r'''#!/bin/bash
for arg; do case "$arg" in --output=*) out="${arg#--output=}" ;; esac; done
case "$(uname -s)" in
  Darwin)
    manifest="$out/App.framework/Resources/flutter_assets"
    library="$out/native_assets/fixture.framework/Versions/A/fixture"
    ;;
  *)
    manifest="$out/flutter_assets"
    library="$out/native_assets/linux/libfixture.so"
    ;;
esac
mkdir -p "$manifest" "$(dirname "$library")"
printf '%s' "$FIXTURE_MANIFEST" > "$manifest/NativeAssetsManifest.json"
echo library > "$library"
if [ "$(uname -s)" = Darwin ]; then
  ln -sfn A "$out/native_assets/fixture.framework/Versions/Current"
  ln -sfn Versions/Current/fixture "$out/native_assets/fixture.framework/fixture"
fi
''';

void main() {
  final helper = p.normalize(
    p.join(
      Directory.current.path,
      '..',
      '..',
      'native',
      'raccoon_runner',
      'tool',
      'raccoon-device',
    ),
  );
  final target = switch (Platform.isMacOS) {
    true => 'macos_arm64',
    false => 'linux_x64',
  };
  final inBundle = switch (Platform.isMacOS) {
    true => 'fixture.framework/fixture',
    false => 'libfixture.so',
  };
  late Directory temp;
  late String project;
  late String data;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('raccoon_native_manifest');
    project = p.join(temp.path, 'project');
    data = p.join(temp.path, 'data');

    File(p.join(temp.path, 'sdk', 'bin', 'flutter'))
      ..createSync(recursive: true)
      ..writeAsStringSync(_fakeFlutter);
    Process.runSync('chmod', [
      '+x',
      p.join(temp.path, 'sdk', 'bin', 'flutter'),
    ]);
    Directory(p.join(temp.path, 'sdk', 'bin', 'cache')).createSync();

    void write(String path, String contents) =>
        File(p.join(project, path))
          ..createSync(recursive: true)
          ..writeAsStringSync(contents);
    write('pubspec.yaml', 'name: fixture_app\n');
    write('lib/main.dart', 'void main() {}\n');
    write('build/flutter_assets/AssetManifest.bin', '');
    write('fixture_hook/pubspec.yaml', 'name: fixture_hook\n');
    write('fixture_hook/hook/build.dart', 'void main() {}\n');
    write(
      '.dart_tool/package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {'name': 'fixture_hook', 'rootUri': '../fixture_hook'},
          {'name': 'fixture_app', 'rootUri': '../'},
        ],
      }),
    );
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Future<(String, Map<String, List<Object?>>)> install(
    Map<String, List<String>> assets,
  ) async {
    final result = await Process.run(
      helper,
      ['install', p.join(project, 'build', 'flutter_assets'), 'fixture_app'],
      environment: {
        'FLUTTER_ROOT': p.join(temp.path, 'sdk'),
        'XDG_DATA_HOME': data,
        'XDG_RUNTIME_DIR': temp.path,
        'TMPDIR': '${temp.path}/',
        'FIXTURE_MANIFEST': jsonEncode({
          'format-version': [1, 0, 0],
          'native-assets': {target: assets},
        }),
      },
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');

    final installed =
        File(
          p.join(
            data,
            'raccoon',
            'apps',
            'fixture_app',
            'flutter_assets',
            'NativeAssetsManifest.json',
          ),
        ).readAsStringSync();
    final manifest = jsonDecode(installed) as Map<String, Object?>;
    final forHost =
        (manifest['native-assets'] as Map<String, Object?>)[target]
            as Map<String, Object?>;
    return (
      '${result.stderr}',
      {
        for (final MapEntry(:key, :value) in forHost.entries)
          key: value as List<Object?>,
      },
    );
  }

  String installedLibrary() =>
      p.join(data, 'raccoon', 'apps', 'fixture_app', 'native_assets', inBundle);

  test(
    'a code asset named by its @rpath install name loads from the install',
    () async {
      final (said, assets) = await install({
        'package:fixture_hook/fixture.dart': ['absolute', '@rpath/$inBundle'],
      });

      expect(said, contains('1 for this host'));
      expect(assets['package:fixture_hook/fixture.dart'], [
        'absolute',
        installedLibrary(),
      ]);
      expect(File(installedLibrary()).existsSync(), isTrue);

      final (again, _) = await install({
        'package:fixture_hook/fixture.dart': ['absolute', '@rpath/$inBundle'],
      });
      expect(again, contains('1 for this host, unchanged'));
    },
  );

  test(
    'paths by the app bundle\'s layout and older SDKs\' relative ones resolve '
    'alike, and the others stay as they are',
    () async {
      final (_, assets) = await install({
        'package:fixture_hook/relative.dart': ['absolute', inBundle],
        'package:fixture_hook/executable.dart': [
          'absolute',
          '@executable_path/../Frameworks/$inBundle',
        ],
        'package:fixture_hook/loader.dart': [
          'absolute',
          '@loader_path/$inBundle',
        ],
        'package:fixture_hook/elsewhere.dart': [
          'absolute',
          '/usr/lib/libelsewhere.so',
        ],
        'package:fixture_hook/system.dart': ['system', 'libsqlite3.so'],
        'package:fixture_hook/process.dart': ['process'],
        'package:fixture_hook/executable_lookup.dart': ['executable'],
      });

      expect(assets, {
        'package:fixture_hook/relative.dart': ['absolute', installedLibrary()],
        'package:fixture_hook/executable.dart': [
          'absolute',
          installedLibrary(),
        ],
        'package:fixture_hook/loader.dart': ['absolute', installedLibrary()],
        'package:fixture_hook/elsewhere.dart': [
          'absolute',
          '/usr/lib/libelsewhere.so',
        ],
        'package:fixture_hook/system.dart': ['system', 'libsqlite3.so'],
        'package:fixture_hook/process.dart': ['process'],
        'package:fixture_hook/executable_lookup.dart': ['executable'],
      });
    },
  );

  test('a code asset the build left out is reported', () async {
    final (said, assets) = await install({
      'package:fixture_hook/gone.dart': ['absolute', '@rpath/libgone.dylib'],
    });

    expect(said, contains('package:fixture_hook/gone.dart'));
    expect(said, contains('is not in the build'));
    expect(assets['package:fixture_hook/gone.dart']?.first, 'absolute');
  });
}

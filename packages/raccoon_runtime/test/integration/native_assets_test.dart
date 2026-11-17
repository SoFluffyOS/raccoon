// Drives the real runner: code assets from build hooks, built and loaded. These
// write into example/native_add and example/native_assets_app, so they stay in
// one file, one at a time. Skipped when the runner or its inputs are not built;
// see native/raccoon_runner/tool/render_example.sh. What the files share is in
// test/support/runner_fixture.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/runner_fixture.dart';

void main() {
  final RunnerFixture(
    :runnerDir,
    :environment,
    :binary,
    :assets,
    :sdk,
    :ready,
  ) = RunnerFixture();
  // #352: native assets were built after the plugins, and the tool's build
  // of them compiles the app's kernel again. The SDK here is a stand-in
  // whose flutter starts the native assets build and says so; the plugin's
  // configure waits for that, which an install building the two one after
  // the other never gets to.
  test(
    'on Linux native assets build beside the plugins',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_beside');
      addTearDown(() => temp.deleteSync(recursive: true));
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      final started = p.join(temp.path, 'native_assets_started');
      final stand = p.join(temp.path, 'sdk');
      write(
        'sdk/bin/cache/engine.stamp',
        File(p.join(sdk!, 'bin', 'cache', 'engine.stamp')).readAsStringSync(),
      );
      // flutter assemble ... --output=DIR: a manifest with nothing for this
      // host, as for objective_c on Linux.
      write(
        'sdk/bin/flutter',
        '#!/bin/sh\n: > "$started"\n'
            'for arg; do case "\$arg" in --output=*) out="\${arg#--output=}" ;; esac; done\n'
            'mkdir -p "\$out/flutter_assets"\n'
            'echo \'{"format-version":[1,0,0],"native-assets":{}}\' '
            '> "\$out/flutter_assets/NativeAssetsManifest.json"\n',
      );
      await Process.run('chmod', ['755', p.join(stand, 'bin', 'flutter')]);
      write(
        'plugin_w/pubspec.yaml',
        'name: plugin_w\nversion: 1.0.0\nflutter:\n  plugin:\n    platforms:\n'
            '      linux:\n        ffiPlugin: true\n',
      );
      write(
        'plugin_w/linux/CMakeLists.txt',
        'cmake_minimum_required(VERSION 3.14)\n'
            'foreach(i RANGE 200)\n'
            '  if(EXISTS "$started")\n    break()\n  endif()\n'
            '  execute_process(COMMAND sleep 0.1)\n'
            'endforeach()\n'
            'if(NOT EXISTS "$started")\n'
            '  message(FATAL_ERROR "no native assets build beside")\n'
            'endif()\n'
            'add_library(plugin_w SHARED plugin_w.cc)\n',
      );
      write(
        'plugin_w/linux/plugin_w.cc',
        'int plugin_w_value() { return 1; }\n',
      );
      write('hooked/pubspec.yaml', 'name: hooked\n');
      write('hooked/hook/build.dart', 'void main(List<String> args) {}\n');
      write('app/pubspec.yaml', 'name: app\n');
      write('app/lib/main.dart', 'void main() {}\n');
      write(
        'app/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            for (final name in ['plugin_w', 'hooked'])
              {'name': name, 'rootUri': '../../$name', 'packageUri': 'lib/'},
          ],
        }),
      );
      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);
      final result = await Process.run(
        p.join(runnerDir, 'tool', 'raccoon-device'),
        ['install', bundle.path, 'app'],
        environment: {
          'RACCOON_RUNNER': binary!,
          'FLUTTER_ROOT': stand,
          'XDG_DATA_HOME': p.join(temp.path, 'data'),
          'RACCOON_PLUGIN_CACHE': p.join(temp.path, 'cache'),
          'RACCOON_NO_PREBUILT': '1',
          'RACCOON_PLUGINS': 'build',
        },
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect('${result.stderr}', contains('1 built: plugin_w'));
      expect('${result.stderr}', contains('native assets ready'));
    },
    skip: switch ((binary != null && sdk != null, Platform.isLinux)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'the Linux half of the helper',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  final nativeAssetsApp = p.join(runnerDir, 'example', 'native_assets_app');
  final nativeAssetsBundle = p.join(nativeAssetsApp, 'build', 'flutter_assets');
  test(
    'a code asset from a build hook loads, on macOS and on Linux',
    () async {
      // native_add's hook compiles add() in C. The tool builds the bundle
      // for the Linux device it thinks Raccoon is: on macOS the helper runs
      // the hooks for this host and installs the library (#53); on Linux the
      // bundle has it already, built for this very host (#57, #367).
      final temp = Directory.systemTemp.createTempSync('raccoon_native');
      final helper = p.join(runnerDir, 'tool', 'raccoon-device');
      final data = p.join(temp.path, 'data');
      final helperEnvironment = {
        'RACCOON_RUNNER': binary!,
        if (sdk != null) 'FLUTTER_ROOT': sdk,
        'XDG_DATA_HOME': data,
        'XDG_RUNTIME_DIR': temp.path,
        'TMPDIR': '${temp.path}/',
      };
      final hadLinux = Directory(p.join(nativeAssetsApp, 'linux')).existsSync();
      // An iOS Runner's Firebase config, which the app's bundle carries on
      // macOS.
      final ios = Directory(p.join(nativeAssetsApp, 'ios'));
      final hadIos = ios.existsSync();
      if (!hadIos) {
        File(p.join(ios.path, 'Runner', 'GoogleService-Info.plist'))
          ..createSync(recursive: true)
          ..writeAsStringSync('<plist><dict/></plist>');
      }
      final ProcessResult install;
      try {
        install = await Process.run(helper, [
          'install',
          nativeAssetsBundle,
          'native_assets_app',
        ], environment: helperEnvironment);
      } finally {
        if (!hadIos) ios.deleteSync(recursive: true);
      }
      expect(install.exitCode, 0, reason: '${install.stderr}');
      expect('${install.stderr}', contains('1 for this host'));
      if (Platform.isLinux) {
        expect('${install.stderr}', contains("from the run's bundle"));
      }
      // The Linux target's engine copy goes again.
      expect(
        Directory(p.join(nativeAssetsApp, 'linux')).existsSync(),
        hadLinux,
      );
      final manifest =
          jsonDecode(
                File(
                  p.join(
                    data,
                    'raccoon',
                    'apps',
                    'native_assets_app',
                    'flutter_assets',
                    'NativeAssetsManifest.json',
                  ),
                ).readAsStringSync(),
              )
              as Map;
      final paths = [
        for (final assets in (manifest['native-assets'] as Map).values)
          for (final path in (assets as Map).values) (path as List).last,
      ];
      expect(paths, hasLength(1));
      expect(File('${paths.single}').existsSync(), isTrue);

      final run = await Process.start(helper, [
        'run',
        'native_assets_app',
      ], environment: helperEnvironment);
      final lines = <String>[];
      run.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(lines.add);
      run.stderr.drain<void>().ignore();
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!lines.any((line) => line.contains('NATIVE:')) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(lines, contains(contains('NATIVE:42')));
        // The app's bundle carries the pubspec's version: 1.2.3+4 (#186).
        if (Platform.isMacOS) {
          final plist =
              File(
                p.join(
                  data,
                  'raccoon',
                  'apps',
                  'native_assets_app',
                  'native_assets_app.app',
                  'Contents',
                  'Info.plist',
                ),
              ).readAsStringSync();
          expect(
            plist,
            contains(
              '<key>CFBundleShortVersionString</key><string>1.2.3</string>',
            ),
          );
          expect(
            plist,
            contains('<key>CFBundleVersion</key><string>4</string>'),
          );
          if (!hadIos) {
            expect(
              File(
                p.join(
                  data,
                  'raccoon',
                  'apps',
                  'native_assets_app',
                  'native_assets_app.app',
                  'Contents',
                  'Resources',
                  'GoogleService-Info.plist',
                ),
              ).existsSync(),
              isTrue,
            );
          }
        }
      } finally {
        run.kill();
        await run.exitCode;
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((
      binary != null &&
          sdk != null &&
          Directory(nativeAssetsBundle).existsSync(),
      Platform.isWindows,
    )) {
      (false, _) => 'build the runner and example/native_assets_app first',
      (_, true) => 'native assets are built on macOS and Linux',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
  test(
    'native assets build again only when their inputs change',
    () async {
      // #111: flutter assemble costs seconds per install; the helper keeps
      // what the last one made while the inputs are the same. A hook's own
      // files are inputs, so touching native_add's builds again.
      final temp = Directory.systemTemp.createTempSync('raccoon_native');
      final helper = p.join(runnerDir, 'tool', 'raccoon-device');
      final environment = {
        'RACCOON_RUNNER': binary!,
        if (sdk != null) 'FLUTTER_ROOT': sdk,
        'XDG_DATA_HOME': p.join(temp.path, 'data'),
        'XDG_RUNTIME_DIR': temp.path,
        'TMPDIR': '${temp.path}/',
      };
      Future<String> install([Map<String, String> extra = const {}]) async {
        final result = await Process.run(
          helper,
          ['install', nativeAssetsBundle, 'native_assets_app'],
          environment: {...environment, ...extra},
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        return '${result.stderr}';
      }

      try {
        File(
          p.join(runnerDir, 'example', 'native_add', 'hook', 'build.dart'),
        ).setLastModifiedSync(DateTime.now());
        final built = await install();
        expect(built, contains('1 for this host'));
        expect(built, isNot(contains('unchanged')));
        // The time it took, from a clock read in the shell (#336): a build
        // that runs flutter assemble takes some, and not hours.
        final took = double.parse(
          RegExp(r'native assets ready in (\d+\.\d) s').firstMatch(built)?[1] ??
              '-1',
        );
        expect(took, inInclusiveRange(0.1, 600), reason: built);

        final again = await install();
        expect(again, contains('1 for this host, unchanged'));

        // #349: cached only reuses an up-to-date build, and builds none:
        // the hook package is reported as a skipped plugin is.
        expect(
          await install({'RACCOON_PLUGINS': 'cached'}),
          contains('1 for this host, unchanged'),
        );
        File(
          p.join(runnerDir, 'example', 'native_add', 'hook', 'build.dart'),
        ).setLastModifiedSync(DateTime.now());
        final skipped = await install({'RACCOON_PLUGINS': 'cached'});
        expect(skipped, contains('native assets not built'));
        expect(skipped, isNot(contains('native assets ready')));
        final app = p.join(
          temp.path,
          'data',
          'raccoon',
          'apps',
          'native_assets_app',
        );
        expect(Directory(p.join(app, 'native_assets')).existsSync(), isFalse);
        final status =
            (jsonDecode(
                      File(
                        p.join(app, 'plugins', 'manifest.json'),
                      ).readAsStringSync(),
                    )
                    as Map)['status']
                as List;
        expect(status, [
          {
            'name': 'native_add',
            'state': 'skipped',
            'detail':
                'not built: native assets are cached only '
                '(RACCOON_PLUGINS=cached)',
          },
        ]);
        // Off has none, and doesn't look.
        final off = await install({'RACCOON_PLUGINS': 'off'});
        expect(off, contains('native assets off'));
        expect(off, isNot(contains('native assets ready')));
        expect(await install(), isNot(contains('unchanged')));

        // A file gone from the hook package, the newest one kept as is:
        // the build is stale.
        final extra = File(
          p.join(runnerDir, 'example', 'native_add', 'hook', 'stale_probe.txt'),
        )..writeAsStringSync('probe');
        extra.setLastModifiedSync(DateTime(2000));
        expect(await install(), contains('1 for this host'));
        extra.deleteSync();
        expect(await install(), isNot(contains('unchanged')));

        // A local package the hook package depends on: its header is an
        // input too.
        expect(await install(), contains('unchanged'));
        File(
          p.join(
            runnerDir,
            'example',
            'native_add_defs',
            'include',
            'native_add_defs.h',
          ),
        ).setLastModifiedSync(DateTime.now());
        expect(await install(), isNot(contains('unchanged')));

        // A source in a folder named build, below the package's own.
        final nested = File(
          p.join(runnerDir, 'example', 'native_add', 'src', 'build', 'x.c'),
        )..createSync(recursive: true);
        try {
          expect(await install(), isNot(contains('unchanged')));
          expect(await install(), contains('unchanged'));
          nested.writeAsStringSync('// changed');
          expect(await install(), isNot(contains('unchanged')));
        } finally {
          nested.parent.deleteSync(recursive: true);
        }

        // A package nested in the hook package, as an example app is, with
        // build output and tool state that change on every run: not inputs.
        final example = Directory(
          p.join(runnerDir, 'example', 'native_add', 'example_probe'),
        );
        File(p.join(example.path, 'pubspec.yaml'))
          ..createSync(recursive: true)
          ..writeAsStringSync('name: example_probe\n');
        try {
          await install();
          expect(await install(), contains('unchanged'));
          File(p.join(example.path, 'build', 'out'))
            ..createSync(recursive: true)
            ..writeAsStringSync('${DateTime.now()}');
          File(p.join(example.path, '.dart_tool', 'state'))
            ..createSync(recursive: true)
            ..writeAsStringSync('${DateTime.now()}');
          expect(await install(), contains('unchanged'));
        } finally {
          example.deleteSync(recursive: true);
        }

        // Flutter's generated ephemeral folders are not inputs either.
        final ephemeral = File(
          p.join(
            runnerDir,
            'example',
            'native_add',
            'linux',
            'flutter',
            'ephemeral',
            'generated',
          ),
        );
        try {
          ephemeral
            ..createSync(recursive: true)
            ..writeAsStringSync('1');
          await install();
          expect(await install(), contains('unchanged'));
          ephemeral.writeAsStringSync('2');
          expect(await install(), contains('unchanged'));
        } finally {
          Directory(
            p.join(runnerDir, 'example', 'native_add', 'linux'),
          ).deleteSync(recursive: true);
        }

        // A folder linked into the package counts through the link.
        final outside = Directory(p.join(temp.path, 'linked_sources'))
          ..createSync();
        final linked = Link(
          p.join(runnerDir, 'example', 'native_add', 'linked_sources'),
        )..createSync(outside.path);
        try {
          await install();
          expect(await install(), contains('unchanged'));
          File(p.join(outside.path, 'y.c')).writeAsStringSync('// new');
          expect(await install(), isNot(contains('unchanged')));
        } finally {
          linked.deleteSync();
        }

        // A dangling link in the package must not cost the app its assets.
        final dangling = Link(
          p.join(runnerDir, 'example', 'native_add', 'dangling_probe'),
        )..createSync(p.join(temp.path, 'nowhere'));
        try {
          expect(await install(), contains('1 for this host'));
        } finally {
          dangling.deleteSync();
        }
        final manifest =
            jsonDecode(
                  File(
                    p.join(
                      temp.path,
                      'data',
                      'raccoon',
                      'apps',
                      'native_assets_app',
                      'flutter_assets',
                      'NativeAssetsManifest.json',
                    ),
                  ).readAsStringSync(),
                )
                as Map;
        final paths = [
          for (final assets in (manifest['native-assets'] as Map).values)
            for (final path in (assets as Map).values) (path as List).last,
        ];
        expect(paths, hasLength(1));
        expect(File('${paths.single}').existsSync(), isTrue);
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example/native_assets_app first',
      (_, true) => 'native assets come from the Flutter tool on Windows',
      _ when !Directory(nativeAssetsBundle).existsSync() =>
        'build example/native_assets_app first',
      // No build of their own there: the run's bundle has them (#367).
      _ when Platform.isLinux => 'Linux takes native assets from the bundle',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

// Drives the real runner: the device helper installs and runs apps: sizes,
// names, versions, data and the engine download. Skipped when the runner or its
// inputs are not built; see native/raccoon_runner/tool/render_example.sh. What
// the files share is in test/support/runner_fixture.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

import '../support/runner_fixture.dart';

// The fixture's helpers, by the names these tests have always used.
const _expectExit = expectExit;
const _runHelper = runHelper;

void main() {
  final RunnerFixture(
    :runnerDir,
    :environment,
    :binary,
    :assets,
    :sdk,
    :revision,
    :engineDir,
    :icu,
    :ready,
    :channelsAssets,
  ) = RunnerFixture();
  // A whole ratio is worked out in the shell, a fractional one by awk.
  for (final (size, pixels) in [
    ('200x150@2', (400, 300)),
    ('200x150@1.5', (300, 225)),
  ]) {
    test(
      'a sized device ($size) starts at its logical size, in pixels times its ratio',
      () async {
        // The helper's --size is logical, as raccoon-phone's 390x844@3 is;
        // the runner takes pixels. A client that never resizes sees the size
        // the runner started at.
        final temp = Directory.systemTemp.createTempSync('raccoon_size');
        final helperEnvironment = {
          'RACCOON_RUNNER': binary!,
          if (sdk != null) 'FLUTTER_ROOT': sdk,
          'XDG_DATA_HOME': p.join(temp.path, 'data'),
          'XDG_RUNTIME_DIR': temp.path,
          'TMPDIR': '${temp.path}/',
          // Where Windows puts the sockets.
          'TMP': temp.path,
        };
        final install = await _runHelper(runnerDir, [
          'install',
          assets,
          'sized',
        ], helperEnvironment);
        expect(install.exitCode, 0, reason: '${install.stderr}');
        final run = await _startHelper(runnerDir, [
          'run',
          '--size',
          size,
          'sized',
        ], helperEnvironment);
        final socket = File(p.join(temp.path, 'raccoon', 'sized.sock'));
        try {
          final deadline = DateTime.now().add(const Duration(seconds: 30));
          while (!socket.existsSync() && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          final client = await RunnerClient.connect(
            UnixSocketEndpoint(socket.path),
          );
          try {
            final frame = await client.frames.first.timeout(
              const Duration(seconds: 15),
            );
            expect((frame.width, frame.height), pixels);
          } finally {
            client.shutdown();
            await client.close();
          }
        } finally {
          run.kill();
          await run.exitCode;
          temp.deleteSync(recursive: true);
        }
      },
      skip: switch (ready) {
        false => 'build the runner and example first',
        true => false,
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
  // #352: the engine was downloaded at run, after the install had built
  // the plugins; install downloads it now, and run still does when install
  // was skipped.
  test(
    'install downloads the engine, and a run without one still gets it',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_engine');
      addTearDown(() => temp.deleteSync(recursive: true));
      // A mirror of the bucket (FLUTTER_STORAGE_BASE_URL), with an engine
      // that is only its library's name: the run below is a stub's.
      final library = p.basename(
        RuntimeStore.engineLibraryOf(RuntimeStore.hostPlatform),
      );
      final zip = ZipEncoder().encodeBytes(
        Archive()..addFile(ArchiveFile.bytes(library, [1, 2, 3])),
      );
      var downloads = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        downloads++;
        request.response.add(zip);
        await request.response.close();
      });
      addTearDown(server.close);
      // Says the engine it was given, and exits.
      final stub = File(p.join(temp.path, 'raccoon_runner'))
        ..writeAsStringSync('#!/bin/sh\necho "engine \$3"\n');
      await Process.run('chmod', ['755', stub.path]);
      final environment = {
        if (sdk != null) 'FLUTTER_ROOT': sdk,
        'XDG_DATA_HOME': p.join(temp.path, 'data'),
        'XDG_RUNTIME_DIR': temp.path,
        'TMPDIR': '${temp.path}/',
        'RACCOON_PLUGINS': 'off',
        'FLUTTER_STORAGE_BASE_URL': 'http://127.0.0.1:${server.port}',
      };
      String engineOf(String cache) =>
          RuntimeStore(cacheDirectory: cache).installed(revision!)!.directory;

      final engines = p.join(temp.path, 'engines');
      final install = await _runHelper(
        runnerDir,
        ['install', assets, 'app'],
        {
          ...environment,
          'RACCOON_RUNNER': binary!,
          'RACCOON_ENGINE_CACHE': engines,
        },
      );
      expect(install.exitCode, 0, reason: '${install.stderr}');
      expect(downloads, 1);
      expect(
        '${install.stderr}',
        contains('Flutter engine $revision downloaded'),
      );
      // The framework's binary on macOS, the library itself elsewhere.
      final installed =
          RuntimeStore(cacheDirectory: engines).installed(revision!)!;
      expect(File(installed.engineLibrary).readAsBytesSync(), [1, 2, 3]);

      // The run takes it as it is.
      final run = await _runHelper(
        runnerDir,
        ['run', 'app'],
        {
          ...environment,
          'RACCOON_RUNNER': stub.path,
          'RACCOON_ENGINE_CACHE': engines,
        },
      );
      expect(run.exitCode, 0, reason: '${run.stderr}');
      expect(downloads, 1);
      expect('${run.stdout}', contains('engine ${engineOf(engines)}'));

      // An app installed before the engine went, as flutter run finds one
      // it need not install again: the run downloads it.
      final other = p.join(temp.path, 'other_engines');
      final skipped = await _runHelper(
        runnerDir,
        ['run', 'app'],
        {
          ...environment,
          'RACCOON_RUNNER': stub.path,
          'RACCOON_ENGINE_CACHE': other,
        },
      );
      expect(skipped.exitCode, 0, reason: '${skipped.stderr}');
      expect(downloads, 2);
      expect('${skipped.stdout}', contains('engine ${engineOf(other)}'));
    },
    skip: switch ((ready && revision != null, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'the stub runner is a shell script',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  // #120: pub encodes a relative rootUri (my%20libs); the helper looked for
  // the encoded folder and skipped the package without a word.
  test(
    'a hook package in a folder with a space is found',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_space');
      final helper = p.join(runnerDir, 'tool', 'raccoon-device');
      final project = Directory(p.join(temp.path, 'app'))..createSync();
      final hooked = Directory(p.join(temp.path, 'my libs', 'hooked'))
        ..createSync(recursive: true);
      File(p.join(hooked.path, 'hook', 'build.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('void main(List<String> args) {}\n');
      File(
        p.join(hooked.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: hooked\n');
      File(
        p.join(project.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: app\n');
      File(p.join(project.path, 'lib', 'main.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('void main() {}\n');
      File(p.join(project.path, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'configVersion': 2,
            'packages': [
              {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
              {
                'name': 'hooked',
                'rootUri': '../../my%20libs/hooked',
                'packageUri': 'lib/',
              },
            ],
          }),
        );
      final bundle = Directory(p.join(project.path, 'build', 'flutter_assets'))
        ..createSync(recursive: true);
      try {
        final install = await Process.run(
          helper,
          ['install', bundle.path, 'space_hook'],
          environment: {
            'RACCOON_RUNNER': binary!,
            if (sdk != null) 'FLUTTER_ROOT': sdk,
            'XDG_DATA_HOME': p.join(temp.path, 'data'),
            'XDG_RUNTIME_DIR': temp.path,
            'TMPDIR': '${temp.path}/',
          },
        );
        // Built or not, the hook was found: the install says something
        // about native assets rather than nothing.
        expect('${install.stderr}', contains('native assets'));
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'native assets are built on macOS and Linux',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'the helper refuses an app name that names a folder outside the app\'s',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_names');
      addTearDown(() => temp.deleteSync(recursive: true));
      final apps = Directory(p.join(temp.path, 'data', 'raccoon', 'apps'));
      final kept = Directory(p.join(apps.path, 'kept'))
        ..createSync(recursive: true);
      final environment = {'XDG_DATA_HOME': p.join(temp.path, 'data')};
      for (final name in ['', '.', '..', 'kept/..', r'kept\..']) {
        for (final verb in ['uninstall', 'run']) {
          final result = await _runHelper(
            runnerDir,
            [verb, name],
            environment,
            asGiven: true,
          );
          expect(result.exitCode, 1, reason: '$verb "$name"');
          expect('${result.stderr}', contains('not an app name'));
        }
      }
      expect(kept.existsSync(), isTrue);

      final result = await _runHelper(runnerDir, [
        'uninstall',
        'kept',
      ], environment);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(kept.existsSync(), isFalse);
      expect(apps.existsSync(), isTrue);
    },
  );
  test(
    'the helper runs nothing in a socket directory that is a link',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_link');
      addTearDown(() => temp.deleteSync(recursive: true));
      final target = Directory(p.join(temp.path, 'target'))..createSync();
      Process.runSync('chmod', ['755', target.path]);
      Link(p.join(temp.path, 'raccoon')).createSync(target.path);
      final helper = p.join(runnerDir, 'tool', 'raccoon-device');
      final environment = {
        'RACCOON_RUNNER': binary!,
        'XDG_DATA_HOME': p.join(temp.path, 'data'),
        'XDG_RUNTIME_DIR': temp.path,
        'TMPDIR': '${temp.path}/',
      };
      final install = await Process.run(helper, [
        'install',
        assets,
        'linked',
      ], environment: environment);
      expect(install.exitCode, 0, reason: '${install.stderr}');

      final run = await Process.run(helper, [
        'run',
        'linked',
      ], environment: environment);
      expect(run.exitCode, 1);
      expect('${run.stderr}', contains('is a link someone left'));
      expect(FileStat.statSync(target.path).mode & 0x1ff, 0x1ed);
      expect(target.listSync(), isEmpty);
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'Windows has no socket directory owners to check',
      _ => false,
    },
  );
  test(
    'the helper says what run is missing rather than failing on it',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_args');
      addTearDown(() => temp.deleteSync(recursive: true));
      Future<ProcessResult> helper(List<String> args) => _runHelper(
        runnerDir,
        args,
        {'RACCOON_RUNNER': binary!, 'XDG_DATA_HOME': p.join(temp.path, 'data')},
      );

      for (final (args, said) in [
        (['run', '--size'], '--size needs a size'),
        (['run', '--instance'], '--instance needs a key'),
        (['run'], 'usage: raccoon-device'),
        (['install', 'only-a-path'], 'usage: raccoon-device'),
        // Taken as the size, it leaves no app: both are said.
        (['run', '--size', 'phone'], 'not phone: left out'),
        (['run', '--size', 'phone'], 'usage: raccoon-device'),
        (['run', '--size', '390x844@0'], 'not 390x844@0: left out'),
      ]) {
        final result = await helper(args);
        expect(result.exitCode, 2, reason: '$args: ${result.stderr}');
        expect('${result.stderr}', contains(said), reason: '$args');
        expect('${result.stderr}', isNot(contains('unbound variable')));
      }

      // A bundle that isn't there is said so, and nothing is made (#346).
      final nowhere = await helper([
        'install',
        p.join(temp.path, 'nowhere', 'build', 'flutter_assets'),
        'app',
      ]);
      expect(nowhere.exitCode, 1, reason: '${nowhere.stderr}');
      expect('${nowhere.stderr}', contains('no app bundle at'));
      expect(Directory(p.join(temp.path, 'data')).existsSync(), isFalse);
    },
    skip: switch (binary != null) {
      false => 'build the runner first',
      true => false,
    },
  );
  test(
    'install finds the project above a bundle deeper than two levels',
    () async {
      // flutter config --build-dir puts the bundle further down: the project
      // is the nearest folder above it with a pubspec (#225, #322).
      final temp = Directory.systemTemp.createTempSync('raccoon_deep');
      addTearDown(() => temp.deleteSync(recursive: true));
      final app = Directory(p.join(temp.path, 'app'));
      final bundle = Directory(
        p.join(app.path, 'out', 'flutter', 'debug', 'assets'),
      )..createSync(recursive: true);
      File(
        p.join(app.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: app\nversion: 3.1.4\n');
      final install = await _runHelper(
        runnerDir,
        ['install', bundle.path, 'app'],
        {
          'RACCOON_RUNNER': binary!,
          if (sdk != null) 'FLUTTER_ROOT': sdk,
          'XDG_DATA_HOME': p.join(temp.path, 'data'),
          'RACCOON_PLUGINS': 'off',
        },
      );
      expect(install.exitCode, 0, reason: '${install.stderr}');
      expect(
        File(
          p.join(temp.path, 'data', 'raccoon', 'apps', 'app', 'version'),
        ).readAsStringSync(),
        '3.1.4',
      );
    },
    skip: switch (binary != null) {
      false => 'build the runner first',
      true => false,
    },
  );
  test(
    'install keeps the app\'s version, without its comment',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_version');
      addTearDown(() => temp.deleteSync(recursive: true));
      final app = Directory(p.join(temp.path, 'app'));
      final bundle = Directory(p.join(app.path, 'build', 'assets'))
        ..createSync(recursive: true);
      File(p.join(app.path, 'pubspec.yaml')).writeAsStringSync(
        'name: app\n  version: 9.9.9\nversion: 2.4.1+17 # release\n',
      );
      final install = await _runHelper(
        runnerDir,
        ['install', bundle.path, 'app'],
        {
          'RACCOON_RUNNER': binary!,
          if (sdk != null) 'FLUTTER_ROOT': sdk,
          'XDG_DATA_HOME': p.join(temp.path, 'data'),
          'RACCOON_PLUGINS': 'off',
        },
      );
      expect(install.exitCode, 0, reason: '${install.stderr}');
      expect(
        File(
          p.join(temp.path, 'data', 'raccoon', 'apps', 'app', 'version'),
        ).readAsStringSync(),
        '2.4.1+17',
      );
    },
    skip: switch (binary != null) {
      false => 'build the runner first',
      true => false,
    },
  );
  // #342: an app with no version got a bundle with none; Flutter's macOS
  // build gives it 1.0.0 (1), which package_info_plus then reads.
  test(
    'an app\'s bundle gives 1.0.0 (1) for no version, and its own name',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_no_version');
      addTearDown(() => temp.deleteSync(recursive: true));
      final app = Directory(p.join(temp.path, 'app'));
      final bundle = Directory(p.join(app.path, 'build', 'assets'))
        ..createSync(recursive: true);
      File(p.join(app.path, 'pubspec.yaml')).writeAsStringSync('name: app\n');
      final data = p.join(temp.path, 'data');
      // Exits at once: only the bundle made around it is looked at.
      final stub = File(p.join(temp.path, 'raccoon_runner'))
        ..writeAsStringSync('#!/bin/sh\nexit 0\n');
      await Process.run('chmod', ['755', stub.path]);
      final helper = p.join(runnerDir, 'tool', 'raccoon-device');
      final environment = {
        if (sdk != null) 'FLUTTER_ROOT': sdk,
        'XDG_DATA_HOME': data,
        'TMPDIR': '${temp.path}/',
        'RACCOON_PLUGINS': 'off',
      };
      final install = await Process.run(
        helper,
        ['install', bundle.path, 'app'],
        environment: {...environment, 'RACCOON_RUNNER': binary!},
      );
      expect(install.exitCode, 0, reason: '${install.stderr}');
      // A bundle is made for an app with native plugins or native assets.
      Directory(
        p.join(data, 'raccoon', 'apps', 'app', 'native_assets'),
      ).createSync();
      final run = await Process.run(
        helper,
        ['run', 'app'],
        environment: {...environment, 'RACCOON_RUNNER': stub.path},
      );
      expect(run.exitCode, 0, reason: '${run.stderr}');
      final plist =
          File(
            p.join(
              data,
              'raccoon',
              'apps',
              'app',
              'app.app',
              'Contents',
              'Info.plist',
            ),
          ).readAsStringSync();
      expect(
        plist,
        contains('<key>CFBundleShortVersionString</key><string>1.0.0</string>'),
      );
      expect(plist, contains('<key>CFBundleVersion</key><string>1</string>'));
      expect(plist, contains('<key>CFBundleName</key><string>app</string>'));

      // #343: an instance names itself as the app does; its identifier,
      // and so its data, stays its own.
      final instanced = await Process.run(
        helper,
        ['install', '--instance', 'phone', bundle.path, 'app'],
        environment: {...environment, 'RACCOON_RUNNER': binary},
      );
      expect(instanced.exitCode, 0, reason: '${instanced.stderr}');
      Directory(
        p.join(data, 'raccoon', 'apps', 'app@phone', 'native_assets'),
      ).createSync();
      final instanceRun = await Process.run(
        helper,
        ['run', '--instance', 'phone', 'app'],
        environment: {...environment, 'RACCOON_RUNNER': stub.path},
      );
      expect(instanceRun.exitCode, 0, reason: '${instanceRun.stderr}');
      final instancePlist =
          File(
            p.join(
              data,
              'raccoon',
              'apps',
              'app@phone',
              'app@phone.app',
              'Contents',
              'Info.plist',
            ),
          ).readAsStringSync();
      expect(
        instancePlist,
        contains('<key>CFBundleName</key><string>app</string>'),
      );
      expect(
        instancePlist,
        contains(
          '<key>CFBundleIdentifier</key><string>dev.raccoon.app.app-phone</string>',
        ),
      );
    },
    skip: switch ((binary != null && sdk != null, Platform.isMacOS)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'app bundles are made on macOS',
      _ => false,
    },
  );
  // #358: package_info_plus reads data/flutter_assets/version.json beside
  // /proc/self/exe, links resolved, and found nothing beside the runner.
  test(
    'on Linux an app runs as its own executable, with its version.json beside it',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_own_exe');
      addTearDown(() => temp.deleteSync(recursive: true));
      final app = Directory(p.join(temp.path, 'app'));
      final bundle = Directory(p.join(app.path, 'build', 'flutter_assets'))
        ..createSync(recursive: true);
      final pubspec = File(p.join(app.path, 'pubspec.yaml'))
        ..writeAsStringSync('name: app\nversion: "1.2.3+45" # the release\n');
      final data = p.join(temp.path, 'data');
      final apps = p.join(data, 'raccoon', 'apps');
      // Says what it was started as, and what is beside it.
      final runners = Directory(p.join(temp.path, 'runner'))..createSync();
      File writeStub(String word) {
        final stub = File(p.join(runners.path, 'raccoon_runner'));
        if (stub.existsSync()) stub.deleteSync();
        stub.writeAsStringSync(
          '#!/bin/sh\necho "$word \$0"\n'
          'cat "\${0%/*}/data/flutter_assets/version.json"\n',
        );
        Process.runSync('chmod', ['755', stub.path]);
        return stub;
      }

      var stub = writeStub('first');
      final library = File(p.join(runners.path, 'libflutter_linux_gtk.so'))
        ..writeAsStringSync('');
      final environment = {
        if (sdk != null) 'FLUTTER_ROOT': sdk,
        'XDG_DATA_HOME': data,
        'XDG_RUNTIME_DIR': temp.path,
        'TMPDIR': '${temp.path}/',
        'RACCOON_PLUGINS': 'off',
        'RACCOON_RUNNER': stub.path,
      };
      Future<ProcessResult> install(List<String> arguments) async {
        final result = await _runHelper(runnerDir, [
          'install',
          ...arguments,
        ], environment);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        return result;
      }

      Future<String> run(List<String> arguments) async {
        final result = await _runHelper(runnerDir, [
          'run',
          ...arguments,
        ], environment);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        return '${result.stdout}';
      }

      await install([bundle.path, 'app']);
      final versionJson = File(
        p.join(apps, 'app', 'flutter_assets', 'version.json'),
      );
      // What `flutter build linux` writes, byte for byte.
      expect(
        versionJson.readAsStringSync(),
        '{"app_name":"app","version":"1.2.3","build_number":"45",'
        '"package_name":"app"}',
      );
      // What path_provider kept under the runner's name moves to the app's.
      final legacy =
          File(
              p.join(
                data,
                'raccoon',
                'data',
                'app',
                'xdg',
                'data',
                'raccoon_runner',
                'shared_preferences.json',
              ),
            )
            ..createSync(recursive: true)
            ..writeAsStringSync('{"flutter.n":42}');

      final executable = p.join(apps, 'app', 'bin', 'app');
      expect(
        await run(['app']),
        allOf(contains('first $executable\n'), contains('"version":"1.2.3"')),
      );
      // The runner itself, not a link the plugin would resolve back to it.
      expect(FileSystemEntity.isLinkSync(executable), isFalse);
      expect(_sameFile(executable, stub.path), isTrue);
      expect(
        _sameFile(
          p.join(apps, 'app', 'bin', 'libflutter_linux_gtk.so'),
          library.path,
        ),
        isTrue,
      );
      expect(legacy.existsSync(), isFalse);
      expect(
        File(
          p.join(
            data,
            'raccoon',
            'data',
            'app',
            'xdg',
            'data',
            'app',
            'shared_preferences.json',
          ),
        ).readAsStringSync(),
        '{"flutter.n":42}',
      );

      // A runner built again is another file: the next run takes it.
      stub = writeStub('second');
      expect(await run(['app']), contains('second $executable\n'));
      expect(_sameFile(executable, stub.path), isTrue);

      // An instance runs under the app's name, from its own folder; no
      // version, none in the file, and none without a build number either.
      pubspec.writeAsStringSync('name: app\n');
      await install(['--instance', 'phone', bundle.path, 'app']);
      expect(
        File(
          p.join(apps, 'app@phone', 'flutter_assets', 'version.json'),
        ).readAsStringSync(),
        '{"app_name":"app","package_name":"app"}',
      );
      expect(
        await run(['--instance', 'phone', 'app']),
        contains('second ${p.join(apps, 'app@phone', 'bin', 'app')}\n'),
      );
      pubspec.writeAsStringSync('name: app\nversion: 2.0.0\n');
      await install(['--instance', 'tablet', bundle.path, 'app']);
      expect(
        File(
          p.join(apps, 'app@tablet', 'flutter_assets', 'version.json'),
        ).readAsStringSync(),
        '{"app_name":"app","version":"2.0.0","package_name":"app"}',
      );
    },
    skip: switch ((ready && revision != null, Platform.isLinux)) {
      (false, _) => 'build the runner and example first',
      (_, false) => 'the executable of an app\'s own is made on Linux',
      _ => false,
    },
  );
  // #341: two installs of one app at once emptied and filled its folder
  // over each other, and left it without its kernel or nested in itself.
  test(
    'installs of one app at once leave it whole',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_at_once');
      addTearDown(() => temp.deleteSync(recursive: true));
      final app = Directory(p.join(temp.path, 'app'));
      final bundle = p.join(app.path, 'build', 'flutter_assets');
      for (final entity in Directory(assets).listSync(recursive: true)) {
        final target = p.join(bundle, p.relative(entity.path, from: assets));
        if (entity is File) {
          File(target).parent.createSync(recursive: true);
          entity.copySync(target);
        }
      }
      File(p.join(app.path, 'pubspec.yaml')).writeAsStringSync('name: app\n');
      List<String> listing(String root) => [
        for (final entity in Directory(root).listSync(recursive: true))
          p.relative(entity.path, from: root),
      ]..sort();
      // On Linux install adds the app's version.json (#358).
      final expected = [
        ...listing(bundle),
        if (Platform.isLinux) 'version.json',
      ]..sort();
      final installed = p.join(
        temp.path,
        'data',
        'raccoon',
        'apps',
        'app',
        'flutter_assets',
      );
      for (var round = 0; round < 3; round++) {
        final results = await Future.wait([
          for (var i = 0; i < 4; i++)
            _runHelper(
              runnerDir,
              ['install', bundle, 'app'],
              {
                'RACCOON_RUNNER': binary!,
                if (sdk != null) 'FLUTTER_ROOT': sdk,
                'XDG_DATA_HOME': p.join(temp.path, 'data'),
                'RACCOON_PLUGINS': 'off',
              },
            ),
        ]);
        for (final result in results) {
          expect(result.exitCode, 0, reason: '${result.stderr}');
        }
        expect(listing(installed), expected, reason: 'round $round');
      }
    },
    skip: switch (ready) {
      false => 'build the runner and example first',
      true => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'the helper says so of a package config that is not one',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_config');
      addTearDown(() => temp.deleteSync(recursive: true));
      final app = Directory(p.join(temp.path, 'app'));
      final bundle = Directory(p.join(app.path, 'build', 'assets'))
        ..createSync(recursive: true);
      File(p.join(app.path, 'pubspec.yaml')).writeAsStringSync('name: app\n');
      File(p.join(app.path, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"configVersion": 2, "packages": ');
      Future<ProcessResult> install(Map<String, String> extra) => _runHelper(
        runnerDir,
        ['install', bundle.path, 'app'],
        {
          'RACCOON_RUNNER': binary!,
          if (sdk != null) 'FLUTTER_ROOT': sdk,
          'XDG_DATA_HOME': p.join(temp.path, 'data'),
          'RACCOON_PLUGIN_CACHE': p.join(temp.path, 'cache'),
          'RACCOON_NO_PREBUILT': '1',
          ...extra,
        },
      );

      // On Windows the plugin builder is plugins_windows.dart, which says
      // the same (#310).
      final built = await install({});
      expect(built.exitCode, 1);
      expect('${built.stderr}', contains('is not a package config'));
      expect('${built.stderr}', isNot(contains('Traceback')));

      // Off reads it for neither: no native plugins and no native assets
      // (#349).
      if (Platform.isWindows) return;
      final off = await install({'RACCOON_PLUGINS': 'off'});
      expect(off.exitCode, 0, reason: '${off.stderr}');
      expect('${off.stderr}', contains('native assets off'));
      expect('${off.stderr}', isNot(contains('Traceback')));
      expect('${off.stderr}', isNot(contains('substitution')));
    },
    skip: switch (binary != null) {
      false => 'build the runner first',
      true => false,
    },
  );
  test(
    'an app starts at the size the board saved for it',
    () async {
      // A device that names no size: the helper reads AppSizes, so the app
      // opens as the board left it (#89).
      final temp = Directory.systemTemp.createTempSync('raccoon_size');
      final data = p.join(temp.path, 'data');
      final helperEnvironment = {
        'RACCOON_RUNNER': binary!,
        if (sdk != null) 'FLUTTER_ROOT': sdk,
        'XDG_DATA_HOME': data,
        'XDG_RUNTIME_DIR': temp.path,
        'TMPDIR': '${temp.path}/',
        // Where Windows puts the sockets.
        'TMP': temp.path,
      };
      final install = await _runHelper(runnerDir, [
        'install',
        assets,
        'saved',
      ], helperEnvironment);
      expect(install.exitCode, 0, reason: '${install.stderr}');
      AppSizes.forHost(
        helperEnvironment,
      ).save('saved', width: 200, height: 150, pixelRatio: 2);
      final run = await _startHelper(runnerDir, [
        'run',
        'saved',
      ], helperEnvironment);
      final socket = File(p.join(temp.path, 'raccoon', 'saved.sock'));
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!socket.existsSync() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final client = await RunnerClient.connect(
          UnixSocketEndpoint(socket.path),
        );
        try {
          final frame = await client.frames.first.timeout(
            const Duration(seconds: 15),
          );
          expect((frame.width, frame.height), (400, 300));
        } finally {
          client.shutdown();
          await client.close();
        }
      } finally {
        run.kill();
        await run.exitCode;
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch (ready) {
      false => 'build the runner and example first',
      true => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'a data directory keeps the app\'s files apart from other apps\'',
    () async {
      // On Linux, path_provider and shared_preferences are Dart only and put
      // every app hosted by one executable under the same XDG directory; the
      // runner points XDG_DATA_HOME into the app's data directory instead.
      // example/channels prints what it sees.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final dataDir = p.join(temp.path, 'data');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: channelsAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          dataDir: dataDir,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!output.any((line) => line.startsWith('XDG_DATA_HOME:')) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          output,
          contains('XDG_DATA_HOME:${p.join(dataDir, 'xdg', 'data')}'),
        );
      } finally {
        final client = await RunnerClient.connect(endpoint);
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch (ready && Directory(channelsAssets).existsSync()) {
      false => 'build the runner and example/channels first',
      // path_provider_windows asks the shell, which no variable moves.
      true when Platform.isWindows => 'no XDG directories on Windows',
      true => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

/// Whether [a] and [b] are one file, by device and inode, links followed:
/// a hard link to [b] is.
bool _sameFile(String a, String b) {
  String id(String path) =>
      '${Process.runSync('stat', ['-L', '-c', '%d:%i', path]).stdout}';
  return id(a) == id(b);
}

/// Starts the device helper as [_runHelper] runs it.
Future<Process> _startHelper(
  String runnerDir,
  List<String> arguments,
  Map<String, String> environment,
) {
  String posix(String value) => value.replaceAll(r'\', '/');
  final helper = p.join(runnerDir, 'tool', 'raccoon-device');
  final launcher = CustomDeviceConfig.hostLauncher;
  return Process.start(
    launcher.firstOrNull ?? helper,
    [if (launcher.isNotEmpty) posix(helper), ...arguments.map(posix)],
    environment: {
      for (final MapEntry(:key, :value) in environment.entries)
        key: posix(value),
    },
  );
}

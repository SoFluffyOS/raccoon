// Drives the real runner: native plugins loaded into the runner answer the app,
// draw textures, and fail in words; channels nobody serves. Skipped when the
// runner or its inputs are not built; see
// native/raccoon_runner/tool/render_example.sh. What the files share is in
// test/support/runner_fixture.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:path/path.dart' as p;
import 'package:raccoon/raccoon.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

import '../support/runner_fixture.dart';

// The fixture's helpers, by the names these tests have always used.
const _red = red;
const _pixel = pixel;
const _expectExit = expectExit;
const _exitCode = runnerExitCode;
const _pluginEntry = pluginEntry;

void main() {
  final RunnerFixture(
    :runnerDir,
    :environment,
    :binary,
    :assets,
    :sdk,
    :engineDir,
    :icu,
    :ready,
    :pluginLibrary,
    :flutterFramework,
    :pluginsAppAssets,
    :pluginsModalAssets,
    :noPluginAssets,
    :noPluginLateAssets,
  ) = RunnerFixture();
  test(
    'a malformed plugin manifest is reported, and the app still runs',
    () async {
      // The helper writes the manifest; a field of the wrong type made the
      // runner throw at startup rather than run the app without plugins.
      for (final content in [
        '[1, 2]',
        '{"flutter_framework": 3, "plugins": [7, {"name": 1, "library": []}],'
            ' "status": [{"name": 2}, "x"]}',
      ]) {
        final temp = Directory.systemTemp.createTempSync('raccoon_test');
        final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
        final manifest = File(p.join(temp.path, 'plugins.json'))
          ..writeAsStringSync(content);
        final runner = await RunnerProcess.start(
          RunnerLaunch(
            runnerBinary: binary ?? '',
            engineDir: engineDir ?? '',
            assets: assets,
            icuData: icu ?? '',
            endpoint: endpoint,
            plugins: manifest.path,
          ),
        );
        final client = await RunnerClient.connect(endpoint);
        try {
          final frame = await client.frames.first.timeout(
            const Duration(seconds: 15),
          );
          expect(_pixel(frame, 400, 300), _red, reason: content);
        } finally {
          client.shutdown();
          await client.close();
          await _expectExit(runner, reason: content);
          temp.deleteSync(recursive: true);
        }
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'a native plugin loaded into the runner answers the app',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final manifest = File(p.join(temp.path, 'plugins.json'))
        ..writeAsStringSync(
          jsonEncode({
            if (flutterFramework != null) 'flutter_framework': flutterFramework,
            'plugins': [
              _pluginEntry('raccoon_echo', pluginLibrary, 'RaccoonEchoPlugin'),
            ],
          }),
        );
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: pluginsAppAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          plugins: manifest.path,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!output.any((line) => line.startsWith('SECURE:')) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        // The plugin answers from GLib's main loop on Linux, the main queue on
        // macOS, the platform thread's messages on Windows: the runner turns
        // the plugins' main loop.
        expect(output, contains('ECHO:echo: hello'));
        // Plugins are called on a thread in a single-threaded apartment,
        // which shell dialogs need (#126).
        if (Platform.isWindows) expect(output, contains('APARTMENT:sta'));
        // flutter_secure_storage's options reach the plugin without what an
        // unsigned process can't have: the login keychain, no access group,
        // no iCloud sync (#87).
        if (Platform.isMacOS) {
          expect(
            output,
            contains(
              'SECURE:accountName=app;synchronizable=false;'
              'useDataProtectionKeyChain=false;usesDataProtectionKeychain=false',
            ),
          );
        }
      } finally {
        final client = await RunnerClient.connect(endpoint);
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready &&
                File(pluginLibrary).existsSync() &&
                Directory(pluginsAppAssets).existsSync()
            ? false
            : 'build the runner with plugins and example/plugins_app first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  // example/plugins_static sets a value through a static-library plugin and
  // reads it through another linked on it, as FlutterFire's are built (#104).
  final pluginsStaticDir = p.join(runnerDir, 'example', 'plugins_static');
  test(
    'an app\'s static-library plugins build into one module and share its state',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      addTearDown(() => temp.deleteSync(recursive: true));
      final out = p.join(temp.path, 'plugins');
      final built = await Process.run(
        p.join(sdk ?? '', 'bin', 'cache', 'dart-sdk', 'bin', 'dart.exe'),
        [
          p.join(runnerDir, 'tool', 'plugins_windows.dart'),
          p.join(pluginsStaticDir, '.dart_tool', 'package_config.json'),
          out,
          'desktop_window window_manager window_size screen_retriever',
          p.join(temp.path, 'cache'),
          File(p.join(runnerDir, 'VERSION')).readAsStringSync().trim(),
          p.join(
            sdk ?? '',
            'bin',
            'cache',
            'artifacts',
            'engine',
            'windows-x64',
          ),
        ],
      );
      expect(
        '${built.stderr}',
        contains('2 built: raccoon_static_core, raccoon_static_user'),
      );
      final manifest =
          jsonDecode(File(p.join(out, 'manifest.json')).readAsStringSync())
              as Map;
      final libraries = {
        for (final entry in manifest['plugins'] as List)
          p.basename('${(entry as Map)['library']}'),
      };
      expect(libraries, {'raccoon_static_plugins.dll'});

      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: p.join(pluginsStaticDir, 'build', 'flutter_assets'),
          icuData: icu ?? '',
          endpoint: endpoint,
          plugins: p.join(out, 'manifest.json'),
        ),
      );
      final said = Completer<String>();
      runner.stdout.listen((line) {
        final at = line.indexOf('STATIC:');
        if (at >= 0 && !said.isCompleted) said.complete(line.substring(at));
      });
      final client = await RunnerClient.connect(endpoint);
      try {
        // 42 from one module; 0 if each plugin had its own copy of the
        // core's state.
        expect(
          await said.future.timeout(const Duration(seconds: 20)),
          'STATIC:42',
        );
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
      }
    },
    skip:
        !Platform.isWindows
            ? 'static plugins are built this way on Windows'
            : ready &&
                Directory(
                  p.join(pluginsStaticDir, 'build', 'flutter_assets'),
                ).existsSync()
            ? false
            : 'build the runner and example/plugins_static first',
    timeout: const Timeout(Duration(minutes: 10)),
  );
  test(
    'an FFI plugin\'s framework is opened for Dart and reported loaded',
    () async {
      // macOS: no class to register, only a framework whose symbols Dart
      // finds in the process or by name. The echo framework stands in.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final manifest = File(p.join(temp.path, 'plugins.json'))
        ..writeAsStringSync(
          jsonEncode({
            'flutter_framework': flutterFramework,
            'plugins': [
              {'name': 'echo_ffi', 'library': pluginLibrary, 'ffi': true},
            ],
          }),
        );
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: pluginsAppAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          plugins: manifest.path,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        final plugins = await client.plugins.first.timeout(
          const Duration(seconds: 10),
        );
        expect(plugins.plugins.single.state, PluginState.PLUGIN_STATE_LOADED);
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isMacOS
            ? 'FFI entries are macOS manifests'
            : ready &&
                File(pluginLibrary).existsSync() &&
                Directory(pluginsAppAssets).existsSync()
            ? false
            : 'build the runner with plugins and example/plugins_app first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'classes two plugins both carry are said once for the two',
    () async {
      // #198: a pod and a package of the same SDK each link it, and the
      // runtime printed a line per class, 25 for Firebase and Google
      // Sign-In. Two libraries with the same two classes stand in.
      final temp = Directory.systemTemp.createTempSync('raccoon_twins');
      final libraries = <String>[];
      for (final name in ['twin_a', 'twin_b']) {
        final source = File(p.join(temp.path, '$name.m'))..writeAsStringSync(
          '#import <Foundation/Foundation.h>\n'
          '@interface RaccoonTwinOne : NSObject\n@end\n'
          '@implementation RaccoonTwinOne\n@end\n'
          '@interface RaccoonTwinTwo : NSObject\n@end\n'
          '@implementation RaccoonTwinTwo\n@end\n',
        );
        final library = p.join(temp.path, 'lib$name.dylib');
        final built = await Process.run('clang', [
          '-dynamiclib',
          '-framework',
          'Foundation',
          source.path,
          '-o',
          library,
        ]);
        expect(built.exitCode, 0, reason: '${built.stderr}');
        libraries.add(library);
      }
      final manifest = File(p.join(temp.path, 'plugins.json'))
        ..writeAsStringSync(
          jsonEncode({
            'flutter_framework': flutterFramework,
            'plugins': [
              for (final (index, library) in libraries.indexed)
                {
                  'name': 'twin_$index',
                  'library': library,
                  'class': 'RaccoonTwinOne',
                },
            ],
          }),
        );
      // Rendered once: its stderr whole, the lines from loading the
      // plugins, which come before a served runner listens, included.
      try {
        final render = await Process.run(binary!, [
          'render',
          '--engine-dir',
          engineDir!,
          '--assets',
          pluginsAppAssets,
          '--icu',
          icu!,
          '--plugins',
          manifest.path,
          '--out',
          p.join(temp.path, 'frame.ppm'),
        ]);
        final stderr = '${render.stderr}';
        expect(stderr, isNot(contains('is implemented in both')));
        expect(
          stderr,
          contains(
            '🦝 2 Objective-C classes are in both libtwin_a.dylib and '
            'libtwin_b.dylib (RaccoonTwinOne, RaccoonTwinTwo); each calls its '
            'own copy, a lookup by name gets either',
          ),
        );
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isMacOS
            ? 'Objective-C classes are macOS'
            : ready &&
                flutterFramework != null &&
                Directory(pluginsAppAssets).existsSync()
            ? false
            : 'build the runner with plugins and example/plugins_app first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'on Windows a plugin that crashes ends the runner as that crash, and says why',
    () async {
      // The crash handler copies out what stderr's pipe still holds; then
      // the process ends as the access violation it was, as Windows reports
      // a crash, not with the C runtime's exit code 3 for a signal.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final manifest = File(p.join(temp.path, 'plugins.json'))
        ..writeAsStringSync(
          jsonEncode({
            'plugins': [
              _pluginEntry('raccoon_echo', pluginLibrary, 'RaccoonEchoPlugin'),
            ],
          }),
        );
      try {
        final serve = await Process.run(
          binary!,
          [
            'serve',
            '--engine-dir',
            engineDir!,
            '--assets',
            pluginsModalAssets,
            '--icu',
            icu!,
            '--plugins',
            manifest.path,
            '--socket',
            p.join(temp.path, 'crash.sock'),
          ],
          environment: {'RACCOON_ECHO_CRASH': '1'},
        ).timeout(const Duration(seconds: 30));
        // STATUS_ACCESS_VIOLATION, as a signed exit code.
        expect(serve.exitCode, -1073741819, reason: '${serve.stderr}');
        expect('${serve.stderr}', contains('RACCOON_CRASH: the reason'));
      } finally {
        // Windows' error reporting can hold the crashed process's files for
        // a while after it ends (past 10 s on a CI machine): the folder goes
        // if it can, and is the temp folder's to clear if not.
        for (var attempt = 0; attempt < 6 && temp.existsSync(); attempt++) {
          try {
            temp.deleteSync(recursive: true);
          } on FileSystemException {
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
        }
      }
    },
    skip:
        !Platform.isWindows
            ? 'the echo plugin crashes on request on Windows'
            : ready &&
                File(pluginLibrary).existsSync() &&
                Directory(pluginsModalAssets).existsSync()
            ? false
            : 'build the runner with plugins and example/plugins_modal first',
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'on Windows a plugin\'s message after the engine stopped is not said to be sent',
    () async {
      // The echo plugin sends one with a reply as it is destroyed, after the
      // engine is gone. Flutter's own DLL says false then; a true leaves a
      // plugin waiting for a reply that never comes (#345).
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final manifest = File(p.join(temp.path, 'plugins.json'))
        ..writeAsStringSync(
          jsonEncode({
            'plugins': [
              _pluginEntry('raccoon_echo', pluginLibrary, 'RaccoonEchoPlugin'),
            ],
          }),
        );
      final socket = p.join(temp.path, 'late.sock');
      final said = File(p.join(temp.path, 'late.txt'));
      final process = await Process.start(
        binary!,
        [
          'serve',
          '--engine-dir',
          engineDir!,
          '--assets',
          pluginsModalAssets,
          '--icu',
          icu!,
          '--plugins',
          manifest.path,
          '--socket',
          socket,
        ],
        environment: {'RACCOON_ECHO_LATE_SEND': said.path},
      );
      final errors = StringBuffer();
      final read = process.stderr.transform(utf8.decoder).forEach(errors.write);
      final listening = Completer<void>();
      process.stdout.transform(utf8.decoder).listen((text) {
        if (text.contains('listening on') && !listening.isCompleted) {
          listening.complete();
        }
      });
      try {
        await listening.future.timeout(const Duration(seconds: 20));
        final client = await RunnerClient.connect(UnixSocketEndpoint(socket));
        await client.hello.timeout(const Duration(seconds: 10));
        client.shutdown();
        await client.close();
        expect(
          await process.exitCode.timeout(const Duration(seconds: 20)),
          0,
          reason: '$errors',
        );
        await read;
        expect(said.readAsStringSync().trim(), 'sent=0 replied=0');
        // What it says as it goes reaches the runner's stderr: the capture
        // stops after the plugins are destroyed (#345).
        expect('$errors', contains('RACCOON_ECHO: destroyed'));
      } finally {
        process.kill();
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isWindows
            ? 'the echo plugin sends late on request on Windows'
            : ready &&
                File(pluginLibrary).existsSync() &&
                Directory(pluginsModalAssets).existsSync()
            ? false
            : 'build the runner with plugins and example/plugins_modal first',
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'on Windows a plugin\'s windows are aware of each monitor\'s DPI',
    () async {
      // As Flutter's runner template declares: a plugin's dialogs are drawn
      // at the monitor's scale, not stretched from 96 DPI (#345).
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final manifest = File(p.join(temp.path, 'plugins.json'))
        ..writeAsStringSync(
          jsonEncode({
            'plugins': [
              _pluginEntry('raccoon_echo', pluginLibrary, 'RaccoonEchoPlugin'),
            ],
          }),
        );
      final said = File(p.join(temp.path, 'dpi.txt'));
      try {
        final render = await Process.run(
          binary!,
          [
            'render',
            '--engine-dir',
            engineDir!,
            '--assets',
            pluginsModalAssets,
            '--icu',
            icu!,
            '--plugins',
            manifest.path,
            '--out',
            p.join(temp.path, 'frame.ppm'),
          ],
          environment: {'RACCOON_ECHO_DPI': said.path},
        ).timeout(const Duration(seconds: 30));
        expect(render.exitCode, 0, reason: '${render.stderr}');
        expect(said.readAsStringSync().trim(), 'per-monitor-v2');
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isWindows
            ? 'DPI awareness is a Windows manifest\'s'
            : ready &&
                File(pluginLibrary).existsSync() &&
                Directory(pluginsModalAssets).existsSync()
            ? false
            : 'build the runner with plugins and example/plugins_modal first',
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'a plugin library that dies as it loads still says why',
    () async {
      // #201: stderr is held while a library maps (#198); a fatal signal
      // writes back what was held before the runner dies.
      final temp = Directory.systemTemp.createTempSync('raccoon_boom');
      final source = File(p.join(temp.path, 'boom.c'))..writeAsStringSync(
        '#include <stdio.h>\n#include <stdlib.h>\n'
        '__attribute__((constructor)) static void boom(void) {\n'
        '  fprintf(stderr, "RACCOON_BOOM: the reason\\n");\n'
        '  abort();\n}\n',
      );
      final library = p.join(temp.path, 'libboom.dylib');
      final built = await Process.run('clang', [
        '-dynamiclib',
        source.path,
        '-o',
        library,
      ]);
      expect(built.exitCode, 0, reason: '${built.stderr}');
      final manifest = File(p.join(temp.path, 'plugins.json'))
        ..writeAsStringSync(
          jsonEncode({
            'flutter_framework': flutterFramework,
            'plugins': [
              {'name': 'boom', 'library': library, 'class': 'Boom'},
            ],
          }),
        );
      try {
        final render = await Process.run(binary!, [
          'render',
          '--engine-dir',
          engineDir!,
          '--assets',
          pluginsAppAssets,
          '--icu',
          icu!,
          '--plugins',
          manifest.path,
          '--out',
          p.join(temp.path, 'frame.ppm'),
        ]);
        expect(render.exitCode, isNot(0));
        expect('${render.stderr}', contains('RACCOON_BOOM: the reason'));
        // Serving, stderr goes through a pipe the runner reads: the reason
        // reached it, and died with it more often than not (#231). A few
        // runs, as it was a race.
        for (var run = 0; run < 3; run++) {
          final serve = await Process.run(binary, [
            'serve',
            '--engine-dir',
            engineDir,
            '--assets',
            pluginsAppAssets,
            '--icu',
            icu,
            '--plugins',
            manifest.path,
            '--socket',
            p.join(temp.path, 'boom.sock'),
          ]).timeout(const Duration(seconds: 30));
          expect(serve.exitCode, isNot(0));
          expect(
            '${serve.stderr}',
            contains('RACCOON_BOOM: the reason'),
            reason: 'run $run',
          );
        }
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isMacOS
            ? 'held stderr is macOS'
            : ready &&
                flutterFramework != null &&
                Directory(pluginsAppAssets).existsSync()
            ? false
            : 'build the runner with plugins and example/plugins_app first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'the runner tells a client what became of the plugins',
    () async {
      // The manifest carries the helper's word on what never got as far as a
      // library; the runner adds its own on what it loaded, and sends the
      // lot after Hello.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final manifest = File(p.join(temp.path, 'plugins.json'))
        ..writeAsStringSync(
          jsonEncode({
            if (flutterFramework != null) 'flutter_framework': flutterFramework,
            'plugins': [
              _pluginEntry('raccoon_echo', pluginLibrary, 'RaccoonEchoPlugin'),
              _pluginEntry(
                'nowhere',
                p.join(temp.path, 'libnowhere_plugin.so'),
                'NowherePlugin',
              ),
            ],
            'status': [
              {
                'name': 'firebase_core',
                'state': 'no_host',
                'detail': 'no Linux implementation',
              },
              {
                'name': 'desktop_window',
                'state': 'built_in',
                'detail': 'the runner answers it',
              },
              {
                'name': 'geolocator_apple',
                'state': 'skipped',
                'detail': 'not built: native plugins are cached only',
              },
              {
                'name': 'yaru_window_linux',
                'state': 'wants_view',
                'detail': 'no implementation on Raccoon: it wants the view',
              },
              {
                'name': 'json_glib_user',
                'state': 'failed',
                'detail':
                    'needs the development files of json-glib-1.0; see '
                    '.../build.log\nthe log\'s second line',
              },
            ],
          }),
        );
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: pluginsAppAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          plugins: manifest.path,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      // The runner's stderr from before the first frame, relayed.
      final logs = <String>[];
      final logged = client.messages
          .where((m) => m.hasLog())
          .listen((m) => logs.add(m.log.message));
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        final plugins = await client.plugins.first.timeout(
          const Duration(seconds: 10),
        );
        final byName = {for (final s in plugins.plugins) s.name: s};
        expect(byName['raccoon_echo']?.state, PluginState.PLUGIN_STATE_LOADED);
        expect(byName['nowhere']?.state, PluginState.PLUGIN_STATE_FAILED);
        expect(byName['nowhere']?.detail, contains('libnowhere_plugin.so'));
        expect(
          byName['firebase_core']?.state,
          PluginState.PLUGIN_STATE_NO_HOST,
        );
        expect(
          byName['desktop_window']?.state,
          PluginState.PLUGIN_STATE_BUILT_IN,
        );
        expect(
          byName['geolocator_apple']?.state,
          PluginState.PLUGIN_STATE_SKIPPED,
        );
        // One that wants the view (#386) is, to a client, one with no
        // implementation here; the runner's line names it and the view.
        expect(
          byName['yaru_window_linux']?.state,
          PluginState.PLUGIN_STATE_NO_HOST,
        );
        expect(
          byName['yaru_window_linux']?.detail,
          'no implementation on Raccoon: it wants the view',
        );
        const wantsView =
            '🦝 plugin yaru_window_linux not loaded: it wants the view '
            '(#365); the app sees no plugin';
        final said = DateTime.now().add(const Duration(seconds: 5));
        while (!logs.any((l) => l.contains(wantsView)) &&
            DateTime.now().isBefore(said)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(logs, contains(contains(wantsView)));
        // Why one didn't load or build is on the runner's line, which a
        // log's reader files as the runner's: a line of its own would read
        // as the app's (#407).
        const notBuilt =
            '🦝 plugin json_glib_user not built: needs the development '
            'files of json-glib-1.0; see .../build.log';
        while (!logs.any((l) => l.contains(notBuilt)) &&
            DateTime.now().isBefore(said)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(logs, contains(endsWith(notBuilt)));
        expect(
          logs,
          contains(
            allOf(
              contains('🦝 plugin nowhere not loaded: '),
              contains('libnowhere_plugin.so'),
            ),
          ),
        );
        expect(
          logs.where((l) => l.trimLeft().startsWith('needs the development')),
          isEmpty,
        );
        for (final line in logs.where(
          (l) => l.contains('nowhere') || l.contains('json_glib_user'),
        )) {
          expect(
            DeviceLogSource.of(line),
            DeviceLogSource.runner,
            reason: line,
          );
        }
        expect(client.latestPlugins, plugins);
        if (Platform.isMacOS) {
          // FlutterMacOS shares classes with the engine library; the
          // runtime's line for each is left out, one line says so.
          await Future<void>.delayed(const Duration(seconds: 1));
          expect(
            logs.where((l) => l.contains('is implemented in both')),
            isEmpty,
          );
          expect(logs, contains(contains('FlutterMacOS shares')));
        }
      } finally {
        await logged.cancel();
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready &&
                File(pluginLibrary).existsSync() &&
                Directory(pluginsAppAssets).existsSync()
            ? false
            : 'build the runner with plugins and example/plugins_app first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'a plugin\'s texture draws through the renderer',
    () async {
      // The echo plugin registers a 64 by 64 pixel-buffer texture, orange;
      // example/plugins_app draws it full screen. The frame a client reads
      // back is then orange: the texture went through the GPU renderer (GL
      // on Linux, Metal on macOS) and the compositor. The software renderer
      // takes no textures.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final manifest = File(p.join(temp.path, 'plugins.json'))
        ..writeAsStringSync(
          jsonEncode({
            if (flutterFramework != null) 'flutter_framework': flutterFramework,
            'plugins': [
              _pluginEntry('raccoon_echo', pluginLibrary, 'RaccoonEchoPlugin'),
            ],
          }),
        );
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: pluginsAppAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          plugins: manifest.path,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!output.any((line) => line.startsWith('TEXTURE:')) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        if (runner.renderer != 'gl' && runner.renderer != 'metal') {
          printOnFailure(
            'software renderer, no textures: ${output.join('\n')}',
          );
          // Linux's registrar refuses the texture. FlutterMacOS's has no way
          // to: the id comes back and nothing draws.
          if (!Platform.isMacOS) {
            expect(output, contains(startsWith('TEXTURE:error')));
          }
          return;
        }
        expect(output, contains(startsWith('TEXTURE:')));
        final orange = await client.frames
            .firstWhere(
              (f) => _pixel(f, 400, 300) == (r: 0xFF, g: 0x8C, b: 0x00),
            )
            .timeout(const Duration(seconds: 15));
        expect(_pixel(orange, 5, 5), (r: 0xFF, g: 0x8C, b: 0x00));
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready &&
                File(pluginLibrary).existsSync() &&
                Directory(pluginsAppAssets).existsSync()
            ? false
            : 'build the runner with plugins and example/plugins_app first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'a texture let go while its frame draws is freed after that frame',
    () async {
      // #123: the runner populated a plugin's texture without a reference
      // of its own, so a plugin letting it go on the platform thread
      // meanwhile freed it under the raster thread, and a pixel-buffer
      // texture's GL name went with no GL context current wherever its
      // last reference did. The echo plugin lets each churn texture go
      // from inside its second frame's copy, waits for that, and counts.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final manifest = File(p.join(temp.path, 'plugins.json'))
        ..writeAsStringSync(
          jsonEncode({
            'plugins': [
              _pluginEntry('raccoon_echo', pluginLibrary, 'RaccoonEchoPlugin'),
            ],
          }),
        );
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: pluginsAppAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          plugins: manifest.path,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      var exited = false;
      unawaited(runner.exitCode.then((_) => exited = true));
      final client = await RunnerClient.connect(endpoint);
      final frames = client.frames.listen((_) {});
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        Future<void> waitFor(String prefix, Duration bound) async {
          final deadline = DateTime.now().add(bound);
          while (!output.any((line) => line.startsWith(prefix)) &&
              !exited &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }

        await waitFor('TEXTURE:', const Duration(seconds: 15));
        if (runner.renderer != 'gl') {
          printOnFailure('no GL renderer, no textures: ${output.join('\n')}');
          return;
        }
        client.sendToApp('raccoon_echo_app', utf8.encode('churn:100'));
        await waitFor('CHURN:', const Duration(seconds: 90));
        printOnFailure(output.join('\n'));
        final report = output.firstWhere((line) => line.startsWith('CHURN:'));
        expect(report, contains('made=100 '));
        expect(report, contains('finalized=100 '));
        expect(report, contains('finalized_in_populate=0 '));
        expect(report, endsWith('no_context=0'));
      } finally {
        await frames.cancel();
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isLinux
            ? 'the churn textures are the Linux echo plugin\'s'
            : ready &&
                File(pluginLibrary).existsSync() &&
                Directory(pluginsAppAssets).existsSync()
            ? false
            : 'build the runner with plugins and example/plugins_app first',
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'a texture unregistered is told so on the raster thread',
    () async {
      // #231: FlutterMacOS tells a texture it was unregistered on the
      // raster thread; the host told it on whichever thread unregistered
      // it, and kept its last frame until another texture drew.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final manifest = File(p.join(temp.path, 'plugins.json'))
        ..writeAsStringSync(
          jsonEncode({
            'flutter_framework': flutterFramework,
            'plugins': [
              _pluginEntry('raccoon_echo', pluginLibrary, 'RaccoonEchoPlugin'),
            ],
          }),
        );
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: pluginsAppAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          plugins: manifest.path,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        await client.frames.first.timeout(const Duration(seconds: 15));
        expect(output, contains(startsWith('TEXTURE:')));
        client.sendToApp('raccoon_echo_app', utf8.encode('untexture'));
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!output.any((line) => line.startsWith('UNTEXTURE:')) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        printOnFailure(output.join('\n'));
        expect(output, contains('UNTEXTURE:raster'));
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isMacOS
            ? 'onTextureUnregistered: is FlutterMacOS\'s'
            : ready &&
                flutterFramework != null &&
                File(pluginLibrary).existsSync() &&
                Directory(pluginsAppAssets).existsSync()
            ? false
            : 'build the runner with plugins and example/plugins_app first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  const lateChannel = 'plugins.flutter.io/absent_plugin';
  const grey = (r: 0x9E, g: 0x9E, b: 0x9E);
  test(
    'a call before the first client waits for it, and the client answers',
    () async {
      // #196: example/no_plugin calls its channel at once in main(); the
      // client comes 400 ms later, as an IDE that polls for runners may.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: noPluginAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final client = await RunnerClient.connect(endpoint);
      // A string, as the standard codec writes 'ok'.
      client.registerChannel(
        pigeonChannel,
        (_) async => Uint8List.fromList([7, 2, 0x6f, 0x6b]),
      );
      try {
        await client.frames.first.timeout(const Duration(seconds: 15));
        expect(
          output.where((line) => line.startsWith('NO_PLUGIN:')).single,
          startsWith('NO_PLUGIN:ok after'),
        );
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(noPluginAssets).existsSync()
            ? false
            : 'build the runner and example/no_plugin first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'a reply the client never sends is answered empty after the bound',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: noPluginLateAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      runner.stderr.listen(output.add);
      final client = await RunnerClient.connect(endpoint);
      // A client that takes the call and never answers.
      final asked = <DateTime>[];
      client.registerChannel(lateChannel, (data) {
        asked.add(DateTime.now());
        return Completer<Uint8List?>().future;
      });
      try {
        // The call at the first frame went out before or after the client
        // took the channel; either way it fails in the end.
        await client.frames
            .firstWhere((frame) => _pixel(frame, 400, 300) == orange)
            .timeout(const Duration(seconds: 20));
        for (final (phase, buttons) in [
          (PointerPhase.POINTER_PHASE_DOWN, 1),
          (PointerPhase.POINTER_PHASE_UP, 0),
        ]) {
          client.sendPointer(
            PointerEvent(
              phase: phase,
              x: 400,
              y: 300,
              buttons: Int64(buttons),
              device: PointerDevice.POINTER_DEVICE_MOUSE,
              pointerId: 1,
            ),
          );
        }
        await client.frames
            .firstWhere((frame) => _pixel(frame, 400, 300) == grey)
            .timeout(const Duration(seconds: 10));
        final tapped = DateTime.now();
        await client.frames
            .firstWhere((frame) => _pixel(frame, 400, 300) == orange)
            .timeout(const Duration(seconds: 15));
        final waited = DateTime.now().difference(tapped);
        final printed = DateTime.now().add(const Duration(seconds: 5));
        while (output.where((line) => line.contains('NO_PLUGIN_LATE:')).length <
                2 &&
            DateTime.now().isBefore(printed)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(asked, isNotEmpty);
        expect(waited, greaterThan(const Duration(seconds: 3)));
        expect(waited, lessThan(const Duration(seconds: 10)));
        expect(
          replyMillis(output, 'NO_PLUGIN_LATE:MissingPluginException'),
          greaterThanOrEqualTo(4000),
        );
        expect(
          output.where(
            (line) =>
                line ==
                '🦝 nothing answered $lateChannel (the client '
                    'did not answer in 5 s); the app sees no plugin',
          ),
          hasLength(1),
          reason: 'once per channel',
        );
        expect(client.startupFailure, isNull);
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(noPluginLateAssets).existsSync()
            ? false
            : 'build the runner and example/no_plugin_late first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

// Drives the real runner: the helper builds an app's native plugins and caches
// them: pods, Swift packages, CMake, prebuilt archives. Skipped when the runner
// or its inputs are not built; see
// native/raccoon_runner/tool/render_example.sh. What the files share is in
// test/support/runner_fixture.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

import '../support/runner_fixture.dart';

// The fixture's helpers, by the names these tests have always used.
const _runHelper = runHelper;

/// Whether [command] is a file on PATH.
bool _onPath(String command) => (Platform.environment['PATH'] ?? '')
    .split(Platform.isWindows ? ';' : ':')
    .any((dir) => dir.isNotEmpty && File(p.join(dir, command)).existsSync());

void main() {
  final RunnerFixture(
    :workspace,
    :runnerDir,
    :environment,
    :binary,
    :assets,
    :sdk,
    :engineDir,
    :icu,
    :ready,
    :pluginsAppAssets,
  ) = RunnerFixture();
  test(
    'on macOS a plugin whose pod needs a cached plugin\'s pod builds',
    () async {
      // plugin_b's pod depends on plugin_a's. The first install builds and
      // caches plugin_a; the second must still find plugin_a's pod to build
      // plugin_b (firebase_analytics on firebase_core, #82).
      final temp = Directory.systemTemp.createTempSync('raccoon_pods');
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      void plugin(
        String name,
        String className, {
        String? needs,
        String? version,
      }) {
        write(
          '$name/pubspec.yaml',
          'name: $name\nversion: 1.0.0\nflutter:\n  plugin:\n    platforms:\n'
              '      macos:\n        pluginClass: $className\n',
        );
        write(
          '$name/macos/$name.podspec',
          "Pod::Spec.new do |s|\n  s.name = '$name'\n  s.version = '1.0.0'\n"
              "  s.summary = '$name'\n  s.homepage = 'https://example.com'\n"
              "  s.license = { :type => 'BSD' }\n  s.author = 'Raccoon'\n"
              "  s.source = { :path => '.' }\n  s.source_files = 'Classes/**/*'\n"
              "  s.dependency 'FlutterMacOS'\n"
              "${needs == null ? '' : "  s.dependency '$needs'${version == null ? '' : ", '$version'"}\n"}"
              "  s.platform = :osx, '10.15'\nend\n",
        );
        write(
          '$name/macos/Classes/$className.h',
          '@import FlutterMacOS;\n'
              '@interface $className : NSObject <FlutterPlugin>\n@end\n',
        );
        write(
          '$name/macos/Classes/$className.m',
          '#import "$className.h"\n@implementation $className\n'
              '+ (void)registerWithRegistrar:(id<FlutterPluginRegistrar>)registrar {}\n'
              '@end\n',
        );
      }

      plugin('plugin_a', 'PluginA');
      plugin('plugin_b', 'PluginB', needs: 'plugin_a');
      void configure(List<String> plugins) {
        write(
          'app/pubspec.yaml',
          'name: app\ndependencies:\n${[for (final name in plugins) '  $name:\n'].join()}',
        );
        write(
          'app/.dart_tool/package_config.json',
          jsonEncode({
            'configVersion': 2,
            'packages': [
              {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
              for (final name in plugins)
                {'name': name, 'rootUri': '../../$name', 'packageUri': 'lib/'},
            ],
          }),
        );
      }

      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);
      final data = p.join(temp.path, 'data');
      var log = '';
      Future<Map<String, Object?>> install() async {
        final result = await Process.run(
          p.join(runnerDir, 'tool', 'raccoon-device'),
          ['install', bundle.path, 'app'],
          environment: {
            'RACCOON_RUNNER': binary!,
            if (sdk != null) 'FLUTTER_ROOT': sdk,
            'XDG_DATA_HOME': data,
            'RACCOON_PLUGIN_CACHE': p.join(temp.path, 'cache'),
            'RACCOON_NO_PREBUILT': '1',
          },
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        log = '${result.stderr}';
        final manifest = File(
          p.join(data, 'raccoon', 'apps', 'app', 'plugins', 'manifest.json'),
        );
        expect(manifest.existsSync(), isTrue, reason: '${result.stderr}');
        return jsonDecode(manifest.readAsStringSync()) as Map<String, Object?>;
      }

      List<String> loaded(Map<String, Object?> manifest) => [
        for (final entry in manifest['plugins'] as List)
          '${(entry as Map)['name']}',
      ];
      try {
        configure(['plugin_a']);
        expect(loaded(await install()), ['plugin_a']);
        // #184: nothing reuses a cached plugin's intermediates.
        final build = p.join(
          data,
          'raccoon',
          'apps',
          'app',
          'plugins',
          'build',
        );
        for (final root in ['obj', 'out']) {
          expect(
            Directory(p.join(build, root, 'plugin_a')).existsSync(),
            isFalse,
          );
        }
        configure(['plugin_a', 'plugin_b']);
        final second = await install();
        expect(second['status'], isEmpty);
        expect(loaded(second), ['plugin_a', 'plugin_b']);

        // #121: a path plugin's Dart code is not its native build; shared
        // native sources outside its platform folder are.
        write('plugin_a/lib/plugin_a.dart', '// changed\n');
        await install();
        expect(log, contains('from the cache: plugin_a'));
        write('plugin_a/src/extra.c', 'int extra(void) { return 1; }\n');
        final rebuilt = await install();
        expect(log, contains('built: plugin_a'));
        expect(loaded(rebuilt), ['plugin_a', 'plugin_b']);
        // #274: plugin_b built against the new plugin_a is an entry of its
        // own, beside the one an app still on the old plugin_a uses.
        expect(
          Directory(p.join(temp.path, 'cache'))
              .listSync()
              .map((entry) => p.basename(entry.path))
              .where(
                (name) =>
                    name.startsWith('plugin_b-') && !name.contains('.partial'),
              ),
          hasLength(2),
        );

        // #183: a pod that wants a version no source has drops its plugin
        // only; CocoaPods lists both, the one it names still builds.
        plugin('plugin_d', 'PluginD');
        plugin('plugin_e', 'PluginE', needs: 'plugin_d', version: '9.9.9');
        configure(['plugin_d', 'plugin_e']);
        final missing = await install();
        expect(loaded(missing), ['plugin_d']);
        expect(
          [
            for (final entry in missing['status'] as List)
              '${(entry as Map)['name']}',
          ],
          ['plugin_e'],
        );

        // #187: a Swift package that does not build leaves the plugin to
        // its podspec.
        plugin('plugin_g', 'PluginG');
        write('plugin_g/macos/plugin_g/Package.swift', 'not a manifest\n');
        configure(['plugin_g']);
        final fallback = await install();
        expect(log, contains('CocoaPods instead'));
        expect(loaded(fallback), ['plugin_g']);
        expect(
          '${((fallback['plugins'] as List).single as Map)['library']}',
          endsWith('plugin_g.framework/plugin_g'),
        );

        // #191: one Swift package that does not resolve (its product named
        // other than Flutter names it) leaves the others to build.
        void swiftPlugin(
          String name,
          String className, {
          String? product,
          String? shared,
          String? needs,
        }) {
          write(
            '$name/pubspec.yaml',
            'name: $name\nversion: 1.0.0\n'
                // Four spaces, as some pubspecs have them (#203).
                '${needs == null ? '' : 'dependencies:\n    $needs:\n'}'
                'flutter:\n  plugin:\n    platforms:\n'
                '      macos:\n        pluginClass: $className\n',
          );
          write(
            '$name/macos/$name/Package.swift',
            '// swift-tools-version: 5.9\nimport PackageDescription\n'
                'let package = Package(name: "$name", platforms: [.macOS("10.15")],\n'
                '  products: [.library(name: "${product ?? name.replaceAll('_', '-')}", targets: ["$name"])],\n'
                '  dependencies: [.package(name: "FlutterFramework", path: "../FlutterFramework")'
                '${shared == null ? '' : ', .package(url: "file://${p.join(temp.path, 'shared')}", exact: "$shared")'}],\n'
                '  targets: [.target(name: "$name", dependencies: [\n'
                '    .product(name: "FlutterFramework", package: "FlutterFramework")'
                '${shared == null ? '' : ', .product(name: "Shared", package: "shared")'}])])\n',
          );
          write(
            '$name/macos/$name/Sources/$name/include/$className.h',
            '#import <FlutterMacOS/FlutterMacOS.h>\n'
                '@interface $className : NSObject <FlutterPlugin>\n@end\n',
          );
          write(
            '$name/macos/$name/Sources/$name/$className.m',
            '#import "$className.h"\n@implementation $className\n'
                '+ (void)registerWithRegistrar:(id<FlutterPluginRegistrar>)registrar {}\n'
                '@end\n',
          );
        }

        swiftPlugin('plugin_h', 'PluginH');
        swiftPlugin('plugin_i', 'PluginI', product: 'PluginI');
        configure(['plugin_h', 'plugin_i']);
        final one = await install();
        expect(loaded(one), ['plugin_h']);
        expect(
          '${((one['plugins'] as List).single as Map)['library']}',
          endsWith('RaccoonPlugins.framework/RaccoonPlugins'),
        );
        expect(
          [
            for (final entry in one['status'] as List)
              '${(entry as Map)['name']}',
          ],
          ['plugin_i'],
        );
        // Left out at once next time, the others from the cache.
        final next = await install();
        expect(log, contains('1 from the cache: plugin_h'));
        expect(
          '${((next['status'] as List).single as Map)['detail']}',
          contains('kept from'),
        );

        // #192: two that want versions of a third no one version gives. The
        // side with fewer plugins tied to it goes, though the error names
        // the other first.
        Future<void> git(List<String> args) async {
          final result = await Process.run('git', [
            '-c',
            'user.name=raccoon',
            '-c',
            'user.email=raccoon@example.com',
            '-c',
            'commit.gpgsign=false',
            '-c',
            'tag.gpgsign=false',
            ...args,
          ], workingDirectory: p.join(temp.path, 'shared'));
          expect(result.exitCode, 0, reason: '${result.stderr}');
        }

        write(
          'shared/Package.swift',
          '// swift-tools-version: 5.9\nimport PackageDescription\n'
              'let package = Package(name: "Shared",\n'
              '  products: [.library(name: "Shared", targets: ["Shared"])],\n'
              '  targets: [.target(name: "Shared")])\n',
        );
        write('shared/Sources/Shared/Shared.swift', 'public let shared = 1\n');
        await git(['init', '-q']);
        await git(['add', '.']);
        await git(['commit', '-qm', 'one']);
        await git(['tag', '1.0.0']);
        write('shared/Sources/Shared/Shared.swift', 'public let shared = 2\n');
        await git(['commit', '-qam', 'two']);
        await git(['tag', '2.0.0']);
        swiftPlugin('plugin_j', 'PluginJ', shared: '1.0.0');
        swiftPlugin('plugin_k', 'PluginK', shared: '2.0.0');
        swiftPlugin('plugin_l', 'PluginL', needs: 'plugin_j');
        configure(['plugin_j', 'plugin_k', 'plugin_l']);
        final conflict = await install();
        expect(loaded(conflict), ['plugin_j', 'plugin_l']);
        expect(
          [
            for (final entry in conflict['status'] as List)
              '${(entry as Map)['name']}',
          ],
          ['plugin_k'],
        );
        // #203: with the other side gone, plugin_k builds again rather than
        // staying left out for a day.
        configure(['plugin_k']);
        final alone = await install();
        expect(loaded(alone), ['plugin_k']);
        expect(alone['status'], isEmpty);
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((binary != null && sdk != null, Platform.isMacOS)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'CocoaPods plugins are macOS',
      _ => false,
    },
    // Pods, Swift packages, their culprits and a version conflict, each
    // built cold: past 5 minutes on an Intel CI runner.
    timeout: const Timeout(Duration(minutes: 10)),
  );
  // #122: one failed download turned prebuilts off for good, and an
  // interrupted unpack left half entries that counted as cached.
  test(
    'on macOS a prebuilt download that fails is asked again next time',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_prebuilt');
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      // A plugin whose pod doesn't compile: never cached, so every install
      // asks for a prebuilt first.
      write(
        'plugin_np/macos/plugin_np.podspec',
        "Pod::Spec.new do |s|\n  s.name = 'plugin_np'\n  s.version = '1.0.0'\n"
            "  s.summary = 'plugin_np'\n  s.homepage = 'https://example.com'\n"
            "  s.license = { :type => 'BSD' }\n  s.author = 'Raccoon'\n"
            "  s.source = { :path => '.' }\n  s.source_files = 'Classes/**/*'\n"
            "  s.dependency 'FlutterMacOS'\n  s.platform = :osx, '10.15'\nend\n",
      );
      write('plugin_np/macos/Classes/PluginNp.m', 'this does not compile\n');
      write(
        'plugin_np/pubspec.yaml',
        'name: plugin_np\nversion: 1.0.0\nflutter:\n  plugin:\n    platforms:\n'
            '      macos:\n        pluginClass: PluginNp\n',
      );
      write('app/pubspec.yaml', 'name: app\ndependencies:\n  plugin_np:\n');
      write(
        'app/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            {
              'name': 'plugin_np',
              'rootUri': '../../plugin_np',
              'packageUri': 'lib/',
            },
          ],
        }),
      );
      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);
      final cache = Directory(p.join(temp.path, 'cache'));
      Future<void> install(String prebuilt) async {
        await Process.run(
          p.join(runnerDir, 'tool', 'raccoon-device'),
          ['install', bundle.path, 'app'],
          environment: {
            'RACCOON_RUNNER': binary!,
            if (sdk != null) 'FLUTTER_ROOT': sdk,
            'XDG_DATA_HOME': p.join(temp.path, 'data'),
            'RACCOON_PLUGIN_CACHE': cache.path,
            'RACCOON_PREBUILT_PLUGINS': prebuilt,
          },
        );
      }

      Iterable<String> names() =>
          cache.existsSync()
              ? cache.listSync().map((e) => p.basename(e.path))
              : const [];
      try {
        // No archive there, as with no network: nothing is remembered.
        await install(Uri.file(p.join(temp.path, 'missing.tar.gz')).toString());
        expect(names().where((n) => n.endsWith('.done')), isEmpty);
        expect(names().where((n) => n.startsWith('.prebuilt-')), isEmpty);

        // A server that hangs up: not remembered either.
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((socket) => socket.destroy());
        try {
          await install('http://127.0.0.1:${server.port}/prebuilt.tar.gz');
        } finally {
          await server.close();
        }
        expect(names().where((n) => n.endsWith('.done')), isEmpty);
        expect(names().where((n) => n.startsWith('.prebuilt-')), isEmpty);

        // An archive there: its entries move in, and the fetch is noted.
        // Nothing in it lands outside the cache, nor passes for an entry or
        // a marker (#299): a chain of links each stepping up, a link and a
        // file beside the entries.
        final archive = p.join(temp.path, 'prebuilt.tar.gz');
        final tar = await Process.run('python3', [
          '-c',
          '''
import io, sys, tarfile
with tarfile.open(sys.argv[1], 'w:gz') as tar:
    def add(name, data=b'x', link=None):
        info = tarfile.TarInfo(name)
        if link is not None:
            info.type, info.linkname = tarfile.SYMTYPE, link
            tar.addfile(info)
        else:
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    add('some-entry/lib.dylib')
    add('some-entry/x', link='..')
    add('some-entry/x/y', link='..')
    add('some-entry/x/y/z', link='..')
    add('some-entry/x/y/z/escaped')
    add('other-entry', link='some-entry')
    add('prebuilt-other.done')
''',
          archive,
        ]);
        expect(tar.exitCode, 0, reason: '${tar.stderr}');
        await install(Uri.file(archive).toString());
        expect(names(), contains('some-entry'));
        expect(names(), isNot(contains('other-entry')));
        expect(names().where((n) => n.endsWith('.done')), hasLength(1));
        expect(names().where((n) => n.startsWith('.prebuilt-')), isEmpty);
        final root = temp.resolveSymbolicLinksSync();
        expect([
          for (final file in temp.listSync(recursive: true).whereType<File>())
            if (p.basename(file.path) == 'escaped' &&
                !p.isWithin(
                  p.join(root, 'cache', 'some-entry'),
                  file.resolveSymbolicLinksSync(),
                ))
              file.path,
        ], isEmpty);
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((binary != null && sdk != null, Platform.isMacOS)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'the macOS plugin builder',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  // #302: the prebuilt plugins were fetched only after the Swift
  // packages had been built, so a cold cache built what the release had.
  test(
    'on macOS a Swift package plugin in the prebuilt archive is not built',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_prebuilt_spm');
      addTearDown(() => temp.deleteSync(recursive: true));
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      // A hosted plugin, keyed by its name and version, with a Swift
      // package that doesn't build and a podspec.
      const hosted = 'pub/.pub-cache/hosted/pub.dev/plugin_sp-1.0.0';
      write(
        '$hosted/pubspec.yaml',
        'name: plugin_sp\nversion: 1.0.0\nflutter:\n  plugin:\n    platforms:\n'
            '      macos:\n        pluginClass: PluginSp\n',
      );
      write('$hosted/macos/plugin_sp.podspec', 'Pod::Spec.new do |s|\nend\n');
      write('$hosted/macos/plugin_sp/Package.swift', 'this is not Swift\n');
      write('app/pubspec.yaml', 'name: app\ndependencies:\n  plugin_sp:\n');
      write(
        'app/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            {
              'name': 'plugin_sp',
              'rootUri': Uri.directory(p.join(temp.path, hosted)).toString(),
              'packageUri': 'lib/',
            },
          ],
        }),
      );
      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);

      // The release's archive: the plugin's pod, built whole.
      final version =
          File(p.join(runnerDir, 'VERSION')).readAsStringSync().trim();
      final arch = '${Process.runSync('uname', ['-m']).stdout}'.trim();
      final entry = 'plugin_sp-1.0.0-$version-$arch';
      write('archive/$entry/plugin_sp.framework/plugin_sp', 'x');
      write('archive/$entry/.complete', '');
      final archive = p.join(temp.path, 'prebuilt.tar.gz');
      final tar = await Process.run('tar', [
        '-czf',
        archive,
        '-C',
        p.join(temp.path, 'archive'),
        entry,
      ]);
      expect(tar.exitCode, 0, reason: '${tar.stderr}');

      final install = await Process.run(
        p.join(runnerDir, 'tool', 'raccoon-device'),
        ['install', bundle.path, 'app'],
        environment: {
          'RACCOON_RUNNER': binary!,
          if (sdk != null) 'FLUTTER_ROOT': sdk,
          'XDG_DATA_HOME': p.join(temp.path, 'data'),
          'RACCOON_PLUGIN_CACHE': p.join(temp.path, 'cache'),
          'RACCOON_PREBUILT_PLUGINS': Uri.file(archive).toString(),
        },
      );
      final said = '${install.stderr}';
      expect(said, contains('1 from the cache: plugin_sp'));
      expect(said, isNot(contains('swift packages did not build')));
      expect(
        Directory(p.join(temp.path, 'cache'))
            .listSync()
            .map((e) => p.basename(e.path))
            .where((name) => name.startsWith('swiftpm-')),
        isEmpty,
      );
    },
    skip: switch ((binary != null && sdk != null, Platform.isMacOS)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'the macOS plugin builder',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'on macOS a pod asking for an older macOS builds for this one',
    () async {
      // plugin_c asks for macOS 10.13 and uses UTType, which is macOS 11:
      // built at 10.13 it doesn't compile, as Flutter's own build never
      // does it (#83).
      final temp = Directory.systemTemp.createTempSync('raccoon_pods');
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      write(
        'plugin_c/pubspec.yaml',
        'name: plugin_c\nversion: 1.0.0\nflutter:\n  plugin:\n    platforms:\n'
            '      macos:\n        pluginClass: PluginC\n',
      );
      write(
        'plugin_c/macos/plugin_c.podspec',
        "Pod::Spec.new do |s|\n  s.name = 'plugin_c'\n  s.version = '1.0.0'\n"
            "  s.summary = 'plugin_c'\n  s.homepage = 'https://example.com'\n"
            "  s.license = { :type => 'BSD' }\n  s.author = 'Raccoon'\n"
            "  s.source = { :path => '.' }\n  s.source_files = 'Classes/**/*'\n"
            "  s.dependency 'FlutterMacOS'\n  s.swift_version = '5.0'\n"
            "  s.platform = :osx, '10.13'\nend\n",
      );
      write(
        'plugin_c/macos/Classes/PluginC.swift',
        'import FlutterMacOS\nimport UniformTypeIdentifiers\n\n'
            'public class PluginC: NSObject, FlutterPlugin {\n'
            '  public static func register(with registrar: FlutterPluginRegistrar) {\n'
            '    _ = UTType.png\n  }\n}\n',
      );
      write('app/pubspec.yaml', 'name: app\ndependencies:\n  plugin_c:\n');
      write(
        'app/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            {
              'name': 'plugin_c',
              'rootUri': '../../plugin_c',
              'packageUri': 'lib/',
            },
          ],
        }),
      );
      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);
      final data = p.join(temp.path, 'data');
      try {
        final result = await Process.run(
          p.join(runnerDir, 'tool', 'raccoon-device'),
          ['install', bundle.path, 'app'],
          environment: {
            'RACCOON_RUNNER': binary!,
            if (sdk != null) 'FLUTTER_ROOT': sdk,
            'XDG_DATA_HOME': data,
            'RACCOON_PLUGIN_CACHE': p.join(temp.path, 'cache'),
            'RACCOON_NO_PREBUILT': '1',
          },
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final manifest =
            jsonDecode(
                  File(
                    p.join(
                      data,
                      'raccoon',
                      'apps',
                      'app',
                      'plugins',
                      'manifest.json',
                    ),
                  ).readAsStringSync(),
                )
                as Map;
        expect(manifest['status'], isEmpty);
        expect(
          [
            for (final entry in manifest['plugins'] as List)
              '${(entry as Map)['name']}',
          ],
          ['plugin_c'],
        );
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((binary != null && sdk != null, Platform.isMacOS)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'CocoaPods plugins are macOS',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
  test(
    'a plugin that fails to build is kept failed until it changes',
    () async {
      // #136: building it again costs pod install and xcodebuild, or
      // CMake, on every install. Kept by its key and the toolchain, for a day; retried at
      // once with RACCOON_RETRY_PLUGINS=1, or when its sources change.
      final temp = Directory.systemTemp.createTempSync('raccoon_pods');
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      write(
        'plugin_f/pubspec.yaml',
        'name: plugin_f\nversion: 1.0.0\nflutter:\n  plugin:\n    platforms:\n'
            '      linux:\n        pluginClass: PluginF\n'
            '      macos:\n        pluginClass: PluginF\n',
      );
      write(
        'plugin_f/macos/plugin_f.podspec',
        "Pod::Spec.new do |s|\n  s.name = 'plugin_f'\n  s.version = '1.0.0'\n"
            "  s.summary = 'plugin_f'\n  s.homepage = 'https://example.com'\n"
            "  s.license = { :type => 'BSD' }\n  s.author = 'Raccoon'\n"
            "  s.source = { :path => '.' }\n  s.source_files = 'Classes/**/*'\n"
            "  s.dependency 'FlutterMacOS'\n  s.platform = :osx, '10.15'\nend\n",
      );
      write(
        'plugin_f/macos/Classes/PluginF.h',
        '@import FlutterMacOS;\n@interface PluginF : NSObject <FlutterPlugin>\n@end\n',
      );
      void source({
        required bool compiles,
        String broken = 'not code;',
      }) => write(
        'plugin_f/macos/Classes/PluginF.m',
        '#import "PluginF.h"\n@implementation PluginF\n'
            '+ (void)registerWithRegistrar:(id<FlutterPluginRegistrar>)registrar {\n'
            '  ${compiles ? '' : broken}\n}\n@end\n',
      );
      write(
        'plugin_f/linux/CMakeLists.txt',
        'cmake_minimum_required(VERSION 3.14)\n'
            'add_library(plugin_f_plugin SHARED plugin_f.cc)\n',
      );
      void linuxSource({required bool compiles, String broken = 'not code;'}) =>
          write(
            'plugin_f/linux/plugin_f.cc',
            compiles ? 'int plugin_f_value() { return 1; }\n' : '$broken\n',
          );
      source(compiles: false);
      linuxSource(compiles: false);
      write('app/pubspec.yaml', 'name: app\ndependencies:\n  plugin_f:\n');
      write(
        'app/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            {
              'name': 'plugin_f',
              'rootUri': '../../plugin_f',
              'packageUri': 'lib/',
            },
          ],
        }),
      );
      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);
      final data = p.join(temp.path, 'data');
      // The detail the helper gave plugin_f, null once it built.
      Future<String?> install({bool retry = false}) async {
        final result = await Process.run(
          p.join(runnerDir, 'tool', 'raccoon-device'),
          ['install', bundle.path, 'app'],
          environment: {
            'RACCOON_RUNNER': binary!,
            if (sdk != null) 'FLUTTER_ROOT': sdk,
            'XDG_DATA_HOME': data,
            'RACCOON_PLUGIN_CACHE': p.join(temp.path, 'cache'),
            'RACCOON_NO_PREBUILT': '1',
            if (retry) 'RACCOON_RETRY_PLUGINS': '1',
          },
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final manifest =
            jsonDecode(
                  File(
                    p.join(
                      data,
                      'raccoon',
                      'apps',
                      'app',
                      'plugins',
                      'manifest.json',
                    ),
                  ).readAsStringSync(),
                )
                as Map;
        for (final entry in manifest['status'] as List) {
          final status = entry as Map;
          if (status['name'] == 'plugin_f') return status['detail'] as String;
        }
        return null;
      }

      try {
        final first = await install();
        expect(first, startsWith('did not build'));
        expect(first, isNot(contains('kept')));
        final kept = await install();
        expect(kept, contains('kept from'));
        // Its log is kept beside the failure: the install's is written over.
        final log = RegExp(r'see (\S+\.log)').firstMatch(kept ?? '')?.group(1);
        expect(log, isNotNull);
        expect(File(log ?? '').readAsStringSync(), contains('not code'));
        expect(await install(retry: true), isNot(contains('kept')));
        source(compiles: true);
        linuxSource(compiles: true);
        expect(await install(), isNull);
        // A build the machine stopped (a full disk) is not the plugin's
        // fault, and is not kept.
        const full = '#error No space left on device';
        source(compiles: false, broken: full);
        linuxSource(compiles: false, broken: full);
        expect(await install(), startsWith('did not build'));
        expect(await install(), isNot(contains('kept')));
        // Nor is one that failed for want of a network (#255).
        const offline = '#error Could not resolve host: cdn.cocoapods.org';
        source(compiles: false, broken: offline);
        linuxSource(compiles: false, broken: offline);
        expect(await install(), startsWith('did not build'));
        expect(await install(), isNot(contains('kept')));
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((binary != null && sdk != null, Platform.isWindows)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, true) => 'Windows builds plugins in its own helper',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
  test(
    'on Linux a plugin gets its target platform and its bundled libraries; '
    'one that made nothing is kept, a configure failure is not',
    () async {
      // #246: three FFI plugins. plugin_b bundles a versioned library and
      // checks FLUTTER_TARGET_PLATFORM; plugin_n builds nothing (jni without
      // a JDK); plugin_c stops CMake configuring (a missing -dev package).
      final temp = Directory.systemTemp.createTempSync('raccoon_linux');
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      void plugin(String name, String cmake) {
        write(
          '$name/pubspec.yaml',
          'name: $name\nversion: 1.0.0\nflutter:\n  plugin:\n    platforms:\n'
              '      linux:\n        ffiPlugin: true\n',
        );
        write('$name/linux/CMakeLists.txt', cmake);
      }

      plugin(
        'plugin_b',
        'cmake_minimum_required(VERSION 3.14)\n'
            'if(NOT FLUTTER_TARGET_PLATFORM MATCHES "^linux-(x64|arm64)\$")\n'
            '  message(FATAL_ERROR "no target platform")\n'
            'endif()\n'
            'add_library(plugin_b SHARED plugin_b.cc)\n'
            'set(plugin_b_bundled_libraries "\$<TARGET_FILE:plugin_b>" '
            '"\${CMAKE_CURRENT_SOURCE_DIR}/libs/libextra.so.1" '
            '"\${CMAKE_CURRENT_SOURCE_DIR}/libs/model.bin" PARENT_SCOPE)\n',
      );
      write(
        'plugin_b/linux/plugin_b.cc',
        'int plugin_b_value() { return 1; }\n',
      );
      write('plugin_b/linux/libs/libextra.so.1', 'not really a library\n');
      write('plugin_b/linux/libs/model.bin', 'data the plugin finds\n');
      plugin('plugin_n', 'cmake_minimum_required(VERSION 3.14)\n');
      plugin(
        'plugin_c',
        'cmake_minimum_required(VERSION 3.14)\n'
            'message(FATAL_ERROR "a -dev package is missing")\n',
      );
      write(
        'app/pubspec.yaml',
        'name: app\ndependencies:\n  plugin_b:\n  plugin_n:\n  plugin_c:\n',
      );
      write(
        'app/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            for (final name in ['plugin_b', 'plugin_n', 'plugin_c'])
              {'name': name, 'rootUri': '../../$name', 'packageUri': 'lib/'},
          ],
        }),
      );
      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);
      final data = p.join(temp.path, 'data');
      final plugins = p.join(data, 'raccoon', 'apps', 'app', 'plugins');
      // Each plugin's state and detail.
      Future<Map<String, String>> install() async {
        final result = await Process.run(
          p.join(runnerDir, 'tool', 'raccoon-device'),
          ['install', bundle.path, 'app'],
          environment: {
            'RACCOON_RUNNER': binary!,
            if (sdk != null) 'FLUTTER_ROOT': sdk,
            'XDG_DATA_HOME': data,
            'RACCOON_PLUGIN_CACHE': p.join(temp.path, 'cache'),
            'RACCOON_NO_PREBUILT': '1',
          },
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final manifest =
            jsonDecode(
                  File(p.join(plugins, 'manifest.json')).readAsStringSync(),
                )
                as Map;
        return {
          for (final entry in (manifest['status'] as List).cast<Map>())
            '${entry['name']}': '${entry['state']}: ${entry['detail']}',
        };
      }

      try {
        final first = await install();
        expect(first.containsKey('plugin_b'), isFalse, reason: '$first');
        expect(
          Directory(
            p.join(plugins, 'lib'),
          ).listSync().map((file) => p.basename(file.path)),
          containsAll(['libplugin_b.so', 'libextra.so.1', 'model.bin']),
        );
        // Its build tree goes once it is cached.
        expect(
          Directory(p.join(plugins, 'build', 'plugin_b')).existsSync(),
          isFalse,
        );
        expect(first['plugin_n'], 'built_nothing: built and made no library');
        expect(first['plugin_c'], startsWith('failed: did not build'));
        final second = await install();
        expect(second['plugin_n'], startsWith('built_nothing: '));
        expect(second['plugin_n'], contains('kept from'));
        expect(second['plugin_c'], isNot(contains('kept')));
        // The cache keeps the versioned library and the data too.
        expect(
          Directory(
            p.join(plugins, 'lib'),
          ).listSync().map((file) => p.basename(file.path)),
          containsAll(['libextra.so.1', 'model.bin']),
        );
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((binary != null && sdk != null, Platform.isLinux)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'the Linux half of the helper',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
  // raccoon#16: printing's Linux code compares int with size_t, which
  // GCC's -Wall flags for C++ and -Werror stops; Flutter builds with clang.
  test(
    'on Linux plugins build with clang, as Flutter\'s Linux build does',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_clang');
      addTearDown(() => temp.deleteSync(recursive: true));
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      write(
        'plugin_s/pubspec.yaml',
        'name: plugin_s\nversion: 1.0.0\nflutter:\n  plugin:\n    platforms:\n'
            '      linux:\n        ffiPlugin: true\n',
      );
      write(
        'plugin_s/linux/CMakeLists.txt',
        'cmake_minimum_required(VERSION 3.14)\n'
            'add_library(plugin_s SHARED plugin_s.cc)\n'
            'apply_standard_settings(plugin_s)\n'
            'set(plugin_s_bundled_libraries "\$<TARGET_FILE:plugin_s>" '
            'PARENT_SCOPE)\n',
      );
      write(
        'plugin_s/linux/plugin_s.cc',
        '#include <cstddef>\n'
            'int plugin_s_value(int i, std::size_t n) { return i < n; }\n',
      );
      write('app/pubspec.yaml', 'name: app\ndependencies:\n  plugin_s:\n');
      write(
        'app/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            {'name': 'plugin_s', 'rootUri': '../../plugin_s'},
          ],
        }),
      );
      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);
      final data = p.join(temp.path, 'data');
      final result = await Process.run(
        p.join(runnerDir, 'tool', 'raccoon-device'),
        ['install', bundle.path, 'app'],
        environment: {
          'RACCOON_RUNNER': binary!,
          if (sdk != null) 'FLUTTER_ROOT': sdk,
          'XDG_DATA_HOME': data,
          'RACCOON_PLUGIN_CACHE': p.join(temp.path, 'cache'),
          'RACCOON_NO_PREBUILT': '1',
          // Not the caller's: the helper's own pick.
          'CC': '',
          'CXX': '',
        },
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final plugins = p.join(data, 'raccoon', 'apps', 'app', 'plugins');
      expect(
        File(p.join(plugins, 'lib', 'libplugin_s.so')).existsSync(),
        isTrue,
        reason: '${result.stderr}',
      );
    },
    skip: switch ((
      binary != null && sdk != null,
      Platform.isLinux,
      _onPath('clang++'),
    )) {
      (false, _, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false, _) => 'the Linux half of the helper',
      (_, _, false) => 'no clang++ here, as Flutter\'s Linux build wants',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  // raccoon#369: desktop_drop names fl_view_get_engine and fl_view_get_id,
  // which it calls only on a view the registrar hands it; the runner's
  // library lacked both, and the plugin didn't load at all.
  test(
    'on Linux a plugin that names the view\'s getters loads',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_view');
      addTearDown(() => temp.deleteSync(recursive: true));
      final library = p.join(temp.path, 'libview_user_plugin.so');
      File(p.join(temp.path, 'view_user.cc')).writeAsStringSync(
        '#include <flutter_linux/flutter_linux.h>\n'
        'extern "C" __attribute__((visibility("default")))\n'
        'void view_user_plugin_register_with_registrar(FlPluginRegistrar* r) {\n'
        '  FlView* view = fl_plugin_registrar_get_view(r);\n'
        '  if (view == nullptr) return;\n'
        '  g_message("%p %ld", fl_view_get_engine(view),\n'
        '            static_cast<long>(fl_view_get_id(view)));\n'
        '}\n',
      );
      final flags = await Process.run('pkg-config', ['--cflags', 'gtk+-3.0']);
      expect(flags.exitCode, 0, reason: '${flags.stderr}');
      final built = await Process.run('c++', [
        '-shared',
        '-fPIC',
        ...'${flags.stdout}'.trim().split(RegExp(r'\s+')),
        '-I${p.join(runnerDir, 'third_party', 'flutter_linux', 'flutter', 'shell', 'platform', 'linux', 'public')}',
        p.join(temp.path, 'view_user.cc'),
        '-L${p.dirname(binary!)}',
        '-lflutter_linux_gtk',
        '-o',
        library,
      ]);
      expect(built.exitCode, 0, reason: '${built.stderr}');
      final manifest = File(p.join(temp.path, 'manifest.json'))
        ..writeAsStringSync(
          jsonEncode({
            'plugins': [
              {
                'name': 'view_user',
                'library': library,
                'symbol': 'view_user_plugin_register_with_registrar',
              },
            ],
            'library_path': temp.path,
          }),
        );
      final render = await Process.run(binary, [
        'render',
        '--engine-dir',
        engineDir!,
        '--assets',
        assets,
        '--icu',
        icu!,
        '--plugins',
        manifest.path,
        '--out',
        p.join(temp.path, 'frame.ppm'),
      ]);
      expect('${render.stderr}', contains('🦝 plugin view_user loaded'));
      expect('${render.stderr}', isNot(contains('undefined symbol')));
    },
    skip: switch ((ready, Platform.isLinux, _onPath('c++'))) {
      (false, _, _) => 'build the runner and example/hello first',
      (_, false, _) => 'the Linux plugin library',
      (_, _, false) => 'no c++ here to build the plugin',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  // raccoon#370: the tool bundles a custom device's assets as for Android,
  // and left out quill_native_bridge_linux's xclip (`platforms: [linux]`).
  test(
    'an install adds the assets the app and its packages give this host',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_assets');
      addTearDown(() => temp.deleteSync(recursive: true));
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      final host = Platform.isMacOS ? 'macos' : 'linux';
      final other = Platform.isMacOS ? 'linux' : 'macos';
      write(
        'pkg/pubspec.yaml',
        'name: pkg\nversion: 1.0.0\nflutter:\n  assets:\n'
            '    - path: assets/tool\n      platforms: [$host]\n'
            '    - path: assets/elsewhere\n      platforms: [$other]\n',
      );
      write('pkg/assets/tool', 'for this host\n');
      write('pkg/assets/elsewhere', 'for another\n');
      write(
        'app/pubspec.yaml',
        'name: app\ndependencies:\n  pkg:\nflutter:\n  assets:\n'
            '    - assets/plain.txt\n'
            '    - path: assets/host/\n      platforms:\n        - android\n'
            '        - $host\n',
      );
      write('app/assets/plain.txt', 'bundled by the tool\n');
      write('app/assets/host/one.txt', 'one\n');
      write('app/assets/host/two.txt', 'two\n');
      write(
        'app/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            {'name': 'pkg', 'rootUri': '../../pkg', 'packageUri': 'lib/'},
          ],
        }),
      );
      // What the tool bundled: an Android asset, as it filters them.
      write('app/build/flutter_assets/assets/host/one.txt', 'bundled\n');
      final data = p.join(temp.path, 'data');
      final result = await Process.run(
        p.join(runnerDir, 'tool', 'raccoon-device'),
        ['install', p.join(temp.path, 'app', 'build', 'flutter_assets'), 'app'],
        environment: {
          'RACCOON_RUNNER': binary!,
          if (sdk != null) 'FLUTTER_ROOT': sdk,
          'XDG_DATA_HOME': data,
          'RACCOON_PLUGIN_CACHE': p.join(temp.path, 'cache'),
          'RACCOON_NO_PREBUILT': '1',
        },
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final installed = p.join(
        data,
        'raccoon',
        'apps',
        'app',
        'flutter_assets',
      );
      String? read(String key) {
        final file = File(p.join(installed, key));
        return file.existsSync() ? file.readAsStringSync() : null;
      }

      expect(read('packages/pkg/assets/tool'), 'for this host\n');
      expect(read('packages/pkg/assets/elsewhere'), isNull);
      expect(read('assets/host/two.txt'), 'two\n');
      // What the tool bundled stays as it is.
      expect(read('assets/host/one.txt'), 'bundled\n');
      expect(
        '${result.stderr}',
        contains(
          '🦝 2 $host assets the tool left out of the bundle: '
          'assets/host/two.txt, packages/pkg/assets/tool',
        ),
      );
    },
    skip: switch ((binary != null, Platform.isWindows)) {
      (false, _) => 'build the runner first',
      (_, true) => 'Windows has no python3 for it',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  // raccoon#371: livekit_client links flutter_webrtc_plugin, flutter_webrtc's
  // target, for its include directories. A desktop build has every plugin's
  // targets in one project; each built in its own, the target was missing.
  test(
    'on Linux a plugin that links another plugin\'s target builds against it',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_linked');
      addTearDown(() => temp.deleteSync(recursive: true));
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      void plugin(String name, String dependencies, String cmake) {
        write(
          '$name/pubspec.yaml',
          'name: $name\nversion: 1.0.0\n$dependencies'
              'flutter:\n  plugin:\n    platforms:\n'
              '      linux:\n        ffiPlugin: true\n',
        );
        write('$name/linux/CMakeLists.txt', cmake);
      }

      plugin(
        'plugin_w',
        '',
        'cmake_minimum_required(VERSION 3.14)\n'
            'add_library(plugin_w_plugin SHARED w.cc)\n'
            'target_include_directories(plugin_w_plugin INTERFACE '
            '"\${CMAKE_CURRENT_SOURCE_DIR}/include")\n',
      );
      write('plugin_w/linux/include/plugin_w.h', 'int plugin_w_value();\n');
      write(
        'plugin_w/linux/w.cc',
        '#include "include/plugin_w.h"\nint plugin_w_value() { return 7; }\n',
      );
      plugin(
        'plugin_l',
        'dependencies:\n  plugin_w:\n',
        'cmake_minimum_required(VERSION 3.14)\n'
            'add_library(plugin_l SHARED l.cc)\n'
            'target_link_libraries(plugin_l PRIVATE plugin_w_plugin)\n',
      );
      write(
        'plugin_l/linux/l.cc',
        '#include <plugin_w.h>\n'
            'int plugin_l_value() { return plugin_w_value() + 1; }\n',
      );
      write('app/pubspec.yaml', 'name: app\ndependencies:\n  plugin_l:\n');
      write(
        'app/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            for (final name in ['plugin_l', 'plugin_w'])
              {'name': name, 'rootUri': '../../$name', 'packageUri': 'lib/'},
          ],
        }),
      );
      write(
        'app/.dart_tool/package_graph.json',
        jsonEncode({
          'roots': ['app'],
          'packages': [
            {
              'name': 'app',
              'dependencies': ['plugin_l'],
            },
            {
              'name': 'plugin_l',
              'dependencies': ['plugin_w'],
            },
            {'name': 'plugin_w', 'dependencies': <String>[]},
          ],
        }),
      );
      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);
      final data = p.join(temp.path, 'data');
      final cache = p.join(temp.path, 'cache');
      final result = await Process.run(
        p.join(runnerDir, 'tool', 'raccoon-device'),
        ['install', bundle.path, 'app'],
        environment: {
          'RACCOON_RUNNER': binary!,
          if (sdk != null) 'FLUTTER_ROOT': sdk,
          'XDG_DATA_HOME': data,
          'RACCOON_PLUGIN_CACHE': cache,
          'RACCOON_NO_PREBUILT': '1',
        },
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        '${result.stderr}',
        contains('2 built: plugin_l, plugin_w'),
        reason: '${result.stderr}',
      );
      final plugins = p.join(data, 'raccoon', 'apps', 'app', 'plugins');
      expect(
        Directory(
          p.join(plugins, 'lib'),
        ).listSync().map((file) => p.basename(file.path)),
        containsAll(['libplugin_l.so', 'libplugin_w_plugin.so']),
      );
      // plugin_w's library comes with its own entry, not plugin_l's.
      final entry = Directory(
        cache,
      ).listSync().whereType<Directory>().singleWhere(
        (folder) => p.basename(folder.path).startsWith('plugin_l-'),
      );
      // Its files, not the stamp of the build that made them (#380).
      expect(
        entry
            .listSync()
            .map((file) => p.basename(file.path))
            .where((name) => name != '.recipe'),
        ['libplugin_l.so'],
      );
    },
    skip: switch ((binary != null && sdk != null, Platform.isLinux)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'the Linux half of the helper',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
  // raccoon#373: cargokit compiles super_native_extensions' crate in a cargo
  // target directory inside the plugin's build, where its proc macros are
  // libraries too; the build copies out the one it gives.
  test(
    'on Linux a plugin keeps no library of a cargo target directory',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_cargo');
      addTearDown(() => temp.deleteSync(recursive: true));
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      write(
        'plugin_r/pubspec.yaml',
        'name: plugin_r\nversion: 1.0.0\n'
            'flutter:\n  plugin:\n    platforms:\n'
            '      linux:\n        ffiPlugin: true\n',
      );
      write(
        'plugin_r/linux/CMakeLists.txt',
        'cmake_minimum_required(VERSION 3.14)\n'
            'add_library(plugin_r SHARED r.cc)\n'
            'add_library(derive_m SHARED m.cc)\n'
            'set_target_properties(derive_m PROPERTIES LIBRARY_OUTPUT_DIRECTORY '
            '"\${CMAKE_CURRENT_BINARY_DIR}/target/release/deps")\n'
            'file(WRITE "\${CMAKE_CURRENT_BINARY_DIR}/target/.rustc_info.json" '
            '"{}")\n',
      );
      write('plugin_r/linux/r.cc', 'int plugin_r_value() { return 7; }\n');
      write('plugin_r/linux/m.cc', 'int derive_m_value() { return 8; }\n');
      write('app/pubspec.yaml', 'name: app\ndependencies:\n  plugin_r:\n');
      write(
        'app/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            {
              'name': 'plugin_r',
              'rootUri': '../../plugin_r',
              'packageUri': 'lib/',
            },
          ],
        }),
      );
      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);
      final data = p.join(temp.path, 'data');
      final cache = p.join(temp.path, 'cache');
      final result = await Process.run(
        p.join(runnerDir, 'tool', 'raccoon-device'),
        ['install', bundle.path, 'app'],
        environment: {
          'RACCOON_RUNNER': binary!,
          if (sdk != null) 'FLUTTER_ROOT': sdk,
          'XDG_DATA_HOME': data,
          'RACCOON_PLUGIN_CACHE': cache,
          'RACCOON_NO_PREBUILT': '1',
        },
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        '${result.stderr}',
        contains('1 built: plugin_r'),
        reason: '${result.stderr}',
      );
      final entry = Directory(
        cache,
      ).listSync().whereType<Directory>().singleWhere(
        (folder) => p.basename(folder.path).startsWith('plugin_r-'),
      );
      expect(
        entry
            .listSync()
            .map((file) => p.basename(file.path))
            .where((name) => name != '.recipe'),
        ['libplugin_r.so'],
      );
      expect(
        Directory(
          p.join(data, 'raccoon', 'apps', 'app', 'plugins', 'lib'),
        ).listSync().map((file) => p.basename(file.path)),
        ['libplugin_r.so'],
      );
    },
    skip: switch ((binary != null && sdk != null, Platform.isLinux)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'the Linux half of the helper',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
  // raccoon#376: flutter_js puts its prebuilt QuickJS bridge in the bundle
  // with an install rule of its own, which a desktop build's install step
  // runs; built on its own, the plugin's install rules never ran.
  test(
    'on Linux what a plugin installs in the bundle\'s lib/ goes with it',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_installed');
      addTearDown(() => temp.deleteSync(recursive: true));
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      write(
        'plugin_q/pubspec.yaml',
        'name: plugin_q\nversion: 1.0.0\n'
            'flutter:\n  plugin:\n    platforms:\n'
            '      linux:\n        ffiPlugin: true\n',
      );
      // flutter_js's own lines: the prefix taken for its build folder's
      // while CMake calls it the default, the bridge installed beneath it.
      write(
        'plugin_q/linux/CMakeLists.txt',
        'cmake_minimum_required(VERSION 3.14)\n'
            'project(plugin_q LANGUAGES CXX)\n'
            'add_library(plugin_q SHARED q.cc)\n'
            'if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)\n'
            '  set(CMAKE_INSTALL_PREFIX "\${PROJECT_BINARY_DIR}/bundle" '
            'CACHE PATH "..." FORCE)\n'
            'endif()\n'
            'install(FILES "\${CMAKE_CURRENT_SOURCE_DIR}/shared/'
            'libplugin_q_bridge.so" DESTINATION "\${CMAKE_INSTALL_PREFIX}/lib")\n',
      );
      write('plugin_q/linux/q.cc', 'int plugin_q_value() { return 7; }\n');
      write('plugin_q/linux/shared/libplugin_q_bridge.so', 'prebuilt\n');
      write('app/pubspec.yaml', 'name: app\ndependencies:\n  plugin_q:\n');
      write(
        'app/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            {
              'name': 'plugin_q',
              'rootUri': '../../plugin_q',
              'packageUri': 'lib/',
            },
          ],
        }),
      );
      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);
      final data = p.join(temp.path, 'data');
      final cache = p.join(temp.path, 'cache');
      final result = await Process.run(
        p.join(runnerDir, 'tool', 'raccoon-device'),
        ['install', bundle.path, 'app'],
        environment: {
          'RACCOON_RUNNER': binary!,
          if (sdk != null) 'FLUTTER_ROOT': sdk,
          'XDG_DATA_HOME': data,
          'RACCOON_PLUGIN_CACHE': cache,
          'RACCOON_NO_PREBUILT': '1',
        },
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        '${result.stderr}',
        contains('1 built: plugin_q'),
        reason: '${result.stderr}',
      );
      final entry = Directory(
        cache,
      ).listSync().whereType<Directory>().singleWhere(
        (folder) => p.basename(folder.path).startsWith('plugin_q-'),
      );
      expect(
        entry
            .listSync()
            .map((file) => p.basename(file.path))
            .where((name) => name != '.recipe')
            .toSet(),
        {'libplugin_q.so', 'libplugin_q_bridge.so'},
      );
      final lib = p.join(data, 'raccoon', 'apps', 'app', 'plugins', 'lib');
      expect(
        File(p.join(lib, 'libplugin_q_bridge.so')).readAsStringSync(),
        'prebuilt\n',
      );
    },
    skip: switch ((binary != null && sdk != null, Platform.isLinux)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'the Linux half of the helper',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
  // raccoon#377: serious_python_linux installs Python's standard library
  // at the bundle's root, beside the executable, where its Dart side looks;
  // the cache kept libraries only, all of them for lib/.
  test(
    'on Linux what a plugin installs beside the executable is there',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_beside');
      addTearDown(() => temp.deleteSync(recursive: true));
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      write(
        'plugin_y/pubspec.yaml',
        'name: plugin_y\nversion: 1.0.0\n'
            'flutter:\n  plugin:\n    platforms:\n'
            '      linux:\n        ffiPlugin: true\n',
      );
      write(
        'plugin_y/linux/CMakeLists.txt',
        'cmake_minimum_required(VERSION 3.14)\n'
            'add_library(plugin_y SHARED y.cc)\n'
            'install(DIRECTORY "\${CMAKE_CURRENT_SOURCE_DIR}/python3.99" '
            'DESTINATION "\${CMAKE_BINARY_DIR}/bundle")\n',
      );
      write('plugin_y/linux/y.cc', 'int plugin_y_value() { return 7; }\n');
      write('plugin_y/linux/python3.99/os.py', 'sep = "/"\n');
      write('app/pubspec.yaml', 'name: app\ndependencies:\n  plugin_y:\n');
      write(
        'app/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            {
              'name': 'plugin_y',
              'rootUri': '../../plugin_y',
              'packageUri': 'lib/',
            },
          ],
        }),
      );
      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);
      final data = p.join(temp.path, 'data');
      final cache = p.join(temp.path, 'cache');
      final bin = p.join(data, 'raccoon', 'apps', 'app', 'bin');
      // Built, then from the cache: both put it beside the executable.
      for (final step in ['1 built: plugin_y', '1 from the cache: plugin_y']) {
        final result = await Process.run(
          p.join(runnerDir, 'tool', 'raccoon-device'),
          ['install', bundle.path, 'app'],
          environment: {
            'RACCOON_RUNNER': binary!,
            if (sdk != null) 'FLUTTER_ROOT': sdk,
            'XDG_DATA_HOME': data,
            'RACCOON_PLUGIN_CACHE': cache,
            'RACCOON_NO_PREBUILT': '1',
          },
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect('${result.stderr}', contains(step), reason: '${result.stderr}');
        expect(
          File(p.join(bin, 'python3.99', 'os.py')).readAsStringSync(),
          'sep = "/"\n',
        );
      }
      final entry = Directory(
        cache,
      ).listSync().whereType<Directory>().singleWhere(
        (folder) => p.basename(folder.path).startsWith('plugin_y-'),
      );
      expect(
        File(p.join(entry.path, 'bundle', 'python3.99', 'os.py')).existsSync(),
        isTrue,
      );
      // Its libraries go to lib/ as before, the folder not among them.
      expect(
        Directory(
          p.join(data, 'raccoon', 'apps', 'app', 'plugins', 'lib'),
        ).listSync().map((file) => p.basename(file.path)),
        ['libplugin_y.so'],
      );
    },
    skip: switch ((binary != null && sdk != null, Platform.isLinux)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'the Linux half of the helper',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
  // raccoon#378: flutter_vodozemac builds its crate through cargokit, which
  // stops on "rustup not found in PATH"; the failure said nothing of Rust
  // and was kept after Rust came, the toolchain's identity without it.
  test(
    'on Linux a plugin that wants Rust says so, and Rust builds it again',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_rust');
      addTearDown(() => temp.deleteSync(recursive: true));
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      write(
        'plugin_z/pubspec.yaml',
        'name: plugin_z\nversion: 1.0.0\n'
            'flutter:\n  plugin:\n    platforms:\n'
            '      linux:\n        ffiPlugin: true\n',
      );
      // What cargokit's build step does without Rust.
      write(
        'plugin_z/linux/CMakeLists.txt',
        'cmake_minimum_required(VERSION 3.14)\n'
            'add_custom_target(plugin_z_cargo ALL COMMAND sh -c '
            '"echo SEVERE: rustup not found in PATH. >&2; exit 1")\n',
      );
      write('app/pubspec.yaml', 'name: app\ndependencies:\n  plugin_z:\n');
      write(
        'app/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            {
              'name': 'plugin_z',
              'rootUri': '../../plugin_z',
              'packageUri': 'lib/',
            },
          ],
        }),
      );
      write('rust/rustup', '#!/bin/sh\necho "rustup 1.28.2"\n');
      Process.runSync('chmod', ['+x', p.join(temp.path, 'rust', 'rustup')]);
      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);
      final data = p.join(temp.path, 'data');
      final cache = p.join(temp.path, 'cache');
      Future<String> install({bool rust = false}) async {
        final result = await Process.run(
          p.join(runnerDir, 'tool', 'raccoon-device'),
          ['install', bundle.path, 'app'],
          environment: {
            'RACCOON_RUNNER': binary!,
            if (sdk != null) 'FLUTTER_ROOT': sdk,
            'XDG_DATA_HOME': data,
            'RACCOON_PLUGIN_CACHE': cache,
            'RACCOON_NO_PREBUILT': '1',
            if (rust)
              'PATH':
                  '${p.join(temp.path, 'rust')}:${Platform.environment['PATH']}',
          },
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        return '${result.stderr}';
      }

      final first = await install();
      expect(first, contains('plugin_z (did not build: needs Rust (rustup)'));
      // Kept while nothing changed...
      expect(await install(), contains('kept from'));
      // ...and built again once rustup is there.
      final again = await install(rust: true);
      expect(again, contains('needs Rust (rustup)'));
      expect(again, isNot(contains('kept from')));
    },
    skip: switch ((binary != null && sdk != null, Platform.isLinux)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'the Linux half of the helper',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
  // raccoon#380: an entry was keyed by the plugin and the runner's version,
  // not by how the helper builds, so flutter_js's and serious_python's
  // entries from before #376 and #377 were kept, without what those add.
  test(
    'on Linux an entry an older helper built is built again, its own kept',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_recipe');
      addTearDown(() => temp.deleteSync(recursive: true));
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      void plugin(String root, String name, String source) {
        write(
          '$root/pubspec.yaml',
          'name: $name\nversion: 1.0.0\nflutter:\n  plugin:\n    platforms:\n'
              '      linux:\n        ffiPlugin: true\n',
        );
        write(
          '$root/linux/CMakeLists.txt',
          'cmake_minimum_required(VERSION 3.14)\n'
              'add_library($name SHARED $name.cc)\n',
        );
        write('$root/linux/$name.cc', source);
      }

      // A path plugin the helper builds, and a hosted one the release's
      // archive had, whose own sources don't compile: built again, it
      // would fail.
      plugin('plugin_r', 'plugin_r', 'int plugin_r_value() { return 1; }\n');
      const hosted = 'pub/.pub-cache/hosted/pub.dev/plugin_h-1.0.0';
      plugin(hosted, 'plugin_h', 'not code;\n');
      write('app/pubspec.yaml', 'name: app\n');
      write(
        'app/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            for (final (package, root) in [
              ('plugin_r', 'plugin_r'),
              ('plugin_h', hosted),
            ])
              {
                'name': package,
                'rootUri': Uri.directory(p.join(temp.path, root)).toString(),
                'packageUri': 'lib/',
              },
          ],
        }),
      );
      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);
      final cache = p.join(temp.path, 'cache');
      // plugin_h's entry as an install before #380 fetched it: no stamp.
      final version =
          File(p.join(runnerDir, 'VERSION')).readAsStringSync().trim();
      final arch = '${Process.runSync('uname', ['-m']).stdout}'.trim();
      final prebuilt = p.join(cache, 'plugin_h-1.0.0-$version-$arch');
      write(p.join(prebuilt, 'libplugin_h.so'), 'prebuilt');
      Future<String> install({String plugins = 'build'}) async {
        final result = await Process.run(
          p.join(runnerDir, 'tool', 'raccoon-device'),
          ['install', bundle.path, 'app'],
          environment: {
            'RACCOON_RUNNER': binary!,
            if (sdk != null) 'FLUTTER_ROOT': sdk,
            'XDG_DATA_HOME': p.join(temp.path, 'data'),
            'RACCOON_PLUGIN_CACHE': cache,
            'RACCOON_NO_PREBUILT': '1',
            // An archive of another's: any hosted plugin may be in it.
            'RACCOON_PREBUILT_PLUGINS':
                Uri.file(p.join(temp.path, 'none.tar.gz')).toString(),
            'RACCOON_PLUGINS': plugins,
          },
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        return '${result.stderr}';
      }

      File recipe() => File(
        p.join(
          Directory(cache)
              .listSync()
              .whereType<Directory>()
              .singleWhere(
                (entry) => p.basename(entry.path).startsWith('plugin_r-path-'),
              )
              .path,
          '.recipe',
        ),
      );
      const again = "plugin_r (again: its cached build was an older helper's)";

      final first = await install();
      expect(first, contains('1 built: plugin_r;'));
      expect(first, contains('1 from the cache: plugin_h'));
      // Its own build is kept...
      expect(await install(), contains('2 from the cache'));
      // ...an older helper's is built again, stamped or from before stamps...
      recipe().writeAsStringSync('0123456789abcdef\n');
      expect(await install(), contains('1 built: $again'));
      final current = recipe().readAsStringSync();
      expect(current, matches(RegExp(r'^[0-9a-f]{16}\n$')));
      recipe().deleteSync();
      expect(await install(), contains('1 built: $again'));
      expect(recipe().readAsStringSync(), current);
      // ...or kept, when nothing may be built.
      recipe().writeAsStringSync('0123456789abcdef\n');
      expect(
        await install(plugins: 'cached'),
        contains(
          "2 from the cache: plugin_r (an older helper's build; "
          'not built again: not built: native plugins are cached only',
        ),
      );
      expect(await install(), contains('1 built: $again'));
      expect(await install(), contains('2 from the cache'));
      // The release's entry stays its own, and says so.
      expect(
        File(p.join(prebuilt, '.recipe')).readAsStringSync(),
        'prebuilt\n',
      );
    },
    skip: switch ((binary != null && sdk != null, Platform.isLinux)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'the Linux half of the helper',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
  // raccoon#16: flutter_secure_storage_linux without libsecret-1's
  // development files said only "did not build; see <log>".
  test(
    'on Linux a plugin a -dev package is missing for says which',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_dev');
      addTearDown(() => temp.deleteSync(recursive: true));
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      write(
        'plugin_m/pubspec.yaml',
        'name: plugin_m\nversion: 1.0.0\nflutter:\n  plugin:\n    platforms:\n'
            '      linux:\n        ffiPlugin: true\n',
      );
      write(
        'plugin_m/linux/CMakeLists.txt',
        'cmake_minimum_required(VERSION 3.14)\n'
            'pkg_check_modules(NOPE REQUIRED IMPORTED_TARGET '
            'raccoon-missing-1>=1.0)\n',
      );
      write('app/pubspec.yaml', 'name: app\ndependencies:\n  plugin_m:\n');
      write(
        'app/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            {'name': 'plugin_m', 'rootUri': '../../plugin_m'},
          ],
        }),
      );
      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);
      final data = p.join(temp.path, 'data');
      final result = await Process.run(
        p.join(runnerDir, 'tool', 'raccoon-device'),
        ['install', bundle.path, 'app'],
        environment: {
          'RACCOON_RUNNER': binary!,
          if (sdk != null) 'FLUTTER_ROOT': sdk,
          'XDG_DATA_HOME': data,
          'RACCOON_PLUGIN_CACHE': p.join(temp.path, 'cache'),
          'RACCOON_NO_PREBUILT': '1',
        },
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final manifest =
          jsonDecode(
                File(
                  p.join(
                    data,
                    'raccoon',
                    'apps',
                    'app',
                    'plugins',
                    'manifest.json',
                  ),
                ).readAsStringSync(),
              )
              as Map;
      final detail = (manifest['status'] as List).cast<Map>().single['detail'];
      expect(
        detail,
        matches(
          RegExp(
            r'^did not build: needs the development files of '
            r'raccoon-missing-1, as flutter run -d linux does: (the package '
            r'that provides pkgconfig\(raccoon-missing-1\)|sudo (dnf|zypper) '
            r"install 'pkgconfig\(raccoon-missing-1\)'); see ",
          ),
        ),
      );
    },
    skip: switch ((binary != null && sdk != null, Platform.isLinux)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'the Linux half of the helper',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  // raccoon#385: webview_win_floating asks for WebKitGTK with
  // pkg_search_module, any one of three; none found said only "did not
  // build; see <log>".
  test(
    'on Linux a plugin whose pkg_search_module finds none says which',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_dev_search');
      addTearDown(() => temp.deleteSync(recursive: true));
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      write(
        'plugin_s/pubspec.yaml',
        'name: plugin_s\nversion: 1.0.0\nflutter:\n  plugin:\n    platforms:\n'
            '      linux:\n        ffiPlugin: true\n',
      );
      write(
        'plugin_s/linux/CMakeLists.txt',
        'cmake_minimum_required(VERSION 3.14)\n'
            'pkg_search_module(NOPE REQUIRED raccoon-missing-4.1 '
            'raccoon-missing-4.2)\n',
      );
      write('app/pubspec.yaml', 'name: app\ndependencies:\n  plugin_s:\n');
      write(
        'app/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            {'name': 'plugin_s', 'rootUri': '../../plugin_s'},
          ],
        }),
      );
      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);
      final data = p.join(temp.path, 'data');
      final result = await Process.run(
        p.join(runnerDir, 'tool', 'raccoon-device'),
        ['install', bundle.path, 'app'],
        environment: {
          'RACCOON_RUNNER': binary!,
          if (sdk != null) 'FLUTTER_ROOT': sdk,
          'XDG_DATA_HOME': data,
          'RACCOON_PLUGIN_CACHE': p.join(temp.path, 'cache'),
          'RACCOON_NO_PREBUILT': '1',
        },
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final manifest =
          jsonDecode(
                File(
                  p.join(
                    data,
                    'raccoon',
                    'apps',
                    'app',
                    'plugins',
                    'manifest.json',
                  ),
                ).readAsStringSync(),
              )
              as Map;
      final detail = (manifest['status'] as List).cast<Map>().single['detail'];
      // Not in the table: named by its module, which dnf and zypper
      // install by (#392).
      expect(
        detail,
        matches(
          RegExp(
            r'^did not build: needs the development files of '
            r'raccoon-missing-4\.1 \(or raccoon-missing-4\.2\), as flutter run '
            r'-d linux does: (the package that provides '
            r'pkgconfig\(raccoon-missing-4\.1\)|sudo (dnf|zypper) install '
            r"'pkgconfig\(raccoon-missing-4\.1\)'); see ",
          ),
        ),
      );
    },
    skip: switch ((binary != null && sdk != null, Platform.isLinux)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'the Linux half of the helper',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  // raccoon#392: a missing module was named, not the package to install.
  // Its words are pkg-config's; CMake stops on them as on a desktop build.
  test(
    'on Linux a plugin missing a -dev package says which one to install',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_dev_install');
      addTearDown(() => temp.deleteSync(recursive: true));
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      write(
        'plugin_j/pubspec.yaml',
        'name: plugin_j\nversion: 1.0.0\nflutter:\n  plugin:\n    platforms:\n'
            '      linux:\n        ffiPlugin: true\n',
      );
      write(
        'plugin_j/linux/CMakeLists.txt',
        'cmake_minimum_required(VERSION 3.14)\n'
            'message(FATAL_ERROR "Package \'json-glib-1.0\', required by '
            '\'virtual:world\', not found")\n',
      );
      write('app/pubspec.yaml', 'name: app\ndependencies:\n  plugin_j:\n');
      write(
        'app/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            {'name': 'plugin_j', 'rootUri': '../../plugin_j'},
          ],
        }),
      );
      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);
      final data = p.join(temp.path, 'data');
      final result = await Process.run(
        p.join(runnerDir, 'tool', 'raccoon-device'),
        ['install', bundle.path, 'app'],
        environment: {
          'RACCOON_RUNNER': binary!,
          if (sdk != null) 'FLUTTER_ROOT': sdk,
          'XDG_DATA_HOME': data,
          'RACCOON_PLUGIN_CACHE': p.join(temp.path, 'cache'),
          'RACCOON_NO_PREBUILT': '1',
        },
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final manifest =
          jsonDecode(
                File(
                  p.join(
                    data,
                    'raccoon',
                    'apps',
                    'app',
                    'plugins',
                    'manifest.json',
                  ),
                ).readAsStringSync(),
              )
              as Map;
      final detail =
          (manifest['status'] as List).cast<Map>().single['detail'] as String;
      const head =
          'did not build: needs the development files of json-glib-1.0, '
          'as flutter run -d linux does: ';
      // By the distro this machine runs, as /etc/os-release names it.
      final release =
          File('/etc/os-release').existsSync()
              ? File('/etc/os-release').readAsStringSync()
              : '';
      final words =
          RegExp(
            r'^(?:ID|ID_LIKE)="?([^"\n]*)',
            multiLine: true,
          ).allMatches(release).expand((m) => m[1]!.split(' ')).toSet();
      if (words.contains('debian') || words.contains('ubuntu')) {
        expect(
          detail,
          startsWith('${head}sudo apt install libjson-glib-dev; see '),
        );
      } else {
        expect(
          detail,
          matches(
            RegExp(
              '^${RegExp.escape(head)}(sudo (apt install libjson-glib-dev|'
              r"(dnf|zypper) install 'pkgconfig\(json-glib-1\.0\)'|pacman -S "
              r'json-glib)|the package that provides pkgconfig\(json-glib-1\.0\))'
              '; see ',
            ),
          ),
        );
      }
      expect(result.stderr, contains(detail));
    },
    skip: switch ((binary != null && sdk != null, Platform.isLinux)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'the Linux half of the helper',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  // #352: the release's archive was fetched before any build, alone, even
  // for an app with none of its plugins.
  test(
    'on Linux the prebuilt archive is fetched beside the builds that need '
    'nothing from it',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_beside');
      addTearDown(() => temp.deleteSync(recursive: true));
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      void plugin(String root, String name, {required bool compiles}) {
        write(
          '$root/pubspec.yaml',
          'name: $name\nversion: 1.0.0\nflutter:\n  plugin:\n    platforms:\n'
              '      linux:\n        ffiPlugin: true\n',
        );
        write(
          '$root/linux/CMakeLists.txt',
          'cmake_minimum_required(VERSION 3.14)\n'
              'add_library($name SHARED $name.cc)\n',
        );
        write(
          '$root/linux/$name.cc',
          compiles ? 'int ${name}_value() { return 1; }\n' : 'not code;\n',
        );
      }

      // A path plugin, which no archive holds, and a hosted one, which only
      // the archive has: its own sources don't compile.
      plugin('plugin_p', 'plugin_p', compiles: true);
      const hosted = 'pub/.pub-cache/hosted/pub.dev/plugin_h-1.0.0';
      plugin(hosted, 'plugin_h', compiles: false);
      void app(String name, List<(String, String)> packages) {
        write('$name/pubspec.yaml', 'name: $name\n');
        write(
          '$name/.dart_tool/package_config.json',
          jsonEncode({
            'configVersion': 2,
            'packages': [
              {'name': name, 'rootUri': '../', 'packageUri': 'lib/'},
              for (final (package, root) in packages)
                {
                  'name': package,
                  'rootUri': Uri.directory(p.join(temp.path, root)).toString(),
                  'packageUri': 'lib/',
                },
            ],
          }),
        );
        Directory(
          p.join(temp.path, name, 'build', 'assets'),
        ).createSync(recursive: true);
      }

      app('both', [('plugin_p', 'plugin_p'), ('plugin_h', hosted)]);
      app('path_only', [('plugin_p', 'plugin_p')]);

      // The release's archive: plugin_h's library, by the key an install
      // looks for.
      final version =
          File(p.join(runnerDir, 'VERSION')).readAsStringSync().trim();
      final arch = '${Process.runSync('uname', ['-m']).stdout}'.trim();
      final entry = 'plugin_h-1.0.0-$version-$arch';
      write('archive/$entry/libplugin_h.so', 'prebuilt');
      final archive = p.join(temp.path, 'prebuilt.tar.gz');
      final tar = await Process.run('tar', [
        '-czf',
        archive,
        '-C',
        p.join(temp.path, 'archive'),
        entry,
      ]);
      expect(tar.exitCode, 0, reason: '${tar.stderr}');

      // The archive is answered only once plugin_p is built and cached: an
      // install that built nothing until the fetch was done would wait
      // here for a minute, and get nothing.
      var asked = 0;
      var builtFirst = false;
      String? cacheFor;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        asked++;
        final deadline = DateTime.now().add(const Duration(seconds: 60));
        bool cached() {
          final cache = Directory(cacheFor!);
          return cache.existsSync() &&
              cache.listSync().any((entity) {
                final name = p.basename(entity.path);
                return name.startsWith('plugin_p-path-') &&
                    !name.contains('.partial-');
              });
        }

        while (!(builtFirst = cached()) && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        if (builtFirst) {
          request.response.add(File(archive).readAsBytesSync());
        } else {
          request.response.statusCode = HttpStatus.serviceUnavailable;
        }
        await request.response.close();
      });
      addTearDown(server.close);

      // Each plugin's state and detail, and what the install said.
      Future<(Map<String, String>, String)> install(
        String name,
        String cache,
        String prebuilt,
      ) async {
        cacheFor = cache;
        final result = await Process.run(
          p.join(runnerDir, 'tool', 'raccoon-device'),
          ['install', p.join(temp.path, name, 'build', 'assets'), name],
          environment: {
            'RACCOON_RUNNER': binary!,
            if (sdk != null) 'FLUTTER_ROOT': sdk,
            'XDG_DATA_HOME': p.join(temp.path, 'data'),
            'RACCOON_PLUGIN_CACHE': cache,
            'RACCOON_PREBUILT_PLUGINS': prebuilt,
            'RACCOON_PLUGINS': 'build',
          },
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final manifest =
            jsonDecode(
                  File(
                    p.join(
                      temp.path,
                      'data',
                      'raccoon',
                      'apps',
                      name,
                      'plugins',
                      'manifest.json',
                    ),
                  ).readAsStringSync(),
                )
                as Map;
        return (
          {
            for (final entry in (manifest['status'] as List).cast<Map>())
              '${entry['name']}': '${entry['state']}: ${entry['detail']}',
          },
          '${result.stderr}',
        );
      }

      Iterable<String> names(String cache) =>
          Directory(cache).listSync().map((e) => p.basename(e.path));
      final url = 'http://127.0.0.1:${server.port}/plugins.tar.gz';

      // An app whose plugins no archive holds asks for none.
      final pathOnly = p.join(temp.path, 'cache_path_only');
      final (_, saidPathOnly) = await install('path_only', pathOnly, url);
      expect(saidPathOnly, contains('1 built: plugin_p'));
      expect(asked, 0);
      expect(names(pathOnly).where((n) => n.endsWith('.done')), isEmpty);

      // The path plugin builds while the archive comes; the hosted one
      // waits for it and comes from it.
      final both = p.join(temp.path, 'cache_both');
      final (states, said) = await install('both', both, url);
      expect(asked, 1);
      expect(builtFirst, isTrue, reason: said);
      expect(said, contains('1 built: plugin_p'));
      expect(said, contains('1 from the cache: plugin_h'));
      expect(states, isEmpty);
      expect(names(both).where((n) => n.endsWith('.done')), hasLength(1));

      // A fetch that fails fails no build that needs nothing from it, and
      // is asked again next time.
      final refused = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      refused.listen((socket) => socket.destroy());
      addTearDown(refused.close);
      final failing = p.join(temp.path, 'cache_failing');
      final (failedStates, saidFailing) = await install(
        'both',
        failing,
        'http://127.0.0.1:${refused.port}/plugins.tar.gz',
      );
      expect(saidFailing, contains('1 built: plugin_p'));
      expect(failedStates['plugin_h'], startsWith('failed: did not build'));
      expect(names(failing).where((n) => n.endsWith('.done')), isEmpty);
      expect(names(failing).where((n) => n.startsWith('.prebuilt-')), isEmpty);
    },
    skip: switch ((binary != null && sdk != null, Platform.isLinux)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'the Linux half of the helper',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
  test(
    'on Windows a plugin is cached whole, and rebuilt when its sources change',
    () async {
      // #141: the echo plugin, copied under a folder named hosted (which is
      // not pub's cache), built by the Windows helper on its own.
      final temp = Directory.systemTemp.createTempSync('raccoon_windows');
      final root = p.join(temp.path, 'hosted', 'raccoon_echo');
      final source = p.join(runnerDir, 'example', 'plugins', 'echo');
      for (final file in Directory(source).listSync(recursive: true)) {
        final relative = p.relative(file.path, from: source);
        if (file is! File || relative.startsWith('.')) continue;
        file.copySync(
          (File(p.join(root, relative))
            ..parent.createSync(recursive: true)).path,
        );
      }
      final config =
          File(p.join(temp.path, 'app', '.dart_tool', 'p.json'))
            ..createSync(recursive: true)
            ..writeAsStringSync(
              jsonEncode({
                'configVersion': 2,
                'packages': [
                  {
                    'name': 'raccoon_echo',
                    'rootUri': Uri.directory(root).toString(),
                  },
                ],
              }),
            );
      final cache = p.join(temp.path, 'cache');
      final out = p.join(temp.path, 'out');
      Future<String> build() async {
        final result = await Process.run(
          p.join(sdk!, 'bin', 'cache', 'dart-sdk', 'bin', 'dart.exe'),
          [
            p.join(runnerDir, 'tool', 'plugins_windows.dart'),
            config.path,
            out,
            '',
            cache,
            '0.0.0-test',
            p.join(sdk, 'bin', 'cache', 'artifacts', 'engine', 'windows-x64'),
          ],
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        return '${result.stderr}';
      }

      // A build that failed says why in its log, and CMake's own.
      String log() {
        final build = p.join(out, 'build', 'raccoon_echo');
        return [
          for (final path in [
            p.join(build, 'build.log'),
            p.join(build, 'out', 'CMakeFiles', 'CMakeConfigureLog.yaml'),
          ])
            if (File(path).existsSync()) File(path).readAsStringSync(),
        ].join('\n');
      }

      try {
        expect(await build(), contains('1 built: raccoon_echo'), reason: log());
        final manifest =
            jsonDecode(File(p.join(out, 'manifest.json')).readAsStringSync())
                as Map;
        expect(
          '${(manifest['plugins'] as List).single['library']}',
          endsWith('raccoon_echo_plugin.dll'),
        );
        // One entry, renamed into place; nothing staged left behind.
        final entries = Directory(cache)
            .listSync()
            .whereType<Directory>()
            .map((entry) => p.basename(entry.path))
            .where((name) => name != 'failed');
        expect(entries, [startsWith('raccoon_echo-path-')]);
        expect(await build(), contains('1 from the cache: raccoon_echo'));
        // A source beside windows/, as an FFI plugin's src/.
        File(p.join(root, 'src', 'shared.c'))
          ..createSync(recursive: true)
          ..writeAsStringSync('int shared(void) { return 1; }\n');
        expect(await build(), contains('1 built: raccoon_echo'), reason: log());
        // A CMakeLists.txt saved in a Windows code page, an author's name
        // with a ü in a comment: not UTF-8, and no reason to fail the
        // install.
        final cmake = File(p.join(root, 'windows', 'CMakeLists.txt'));
        cmake.writeAsBytesSync([
          ...'# M'.codeUnits,
          0xFC,
          ...'ller\n'.codeUnits,
          ...cmake.readAsBytesSync(),
        ]);
        expect(await build(), contains('1 built: raccoon_echo'), reason: log());
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((sdk != null, Platform.isWindows)) {
      (false, _) => 'needs a Flutter SDK on PATH',
      (_, false) => 'the Windows plugin helper',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
  test(
    'on macOS a ready-made framework in a plugin\'s pod lands beside it',
    () async {
      // plugin_d's pod brings Ready.xcframework, a dynamic framework the
      // plugin links, as Agora's pods bring AgoraRtcWrapper. CocoaPods
      // leaves it under XCFrameworkIntermediates; without it beside the
      // plugin, the plugin never loads (#84).
      final temp = Directory.systemTemp.createTempSync('raccoon_pods');
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      final ready = p.join(temp.path, 'ready', 'Ready.framework');
      write('ready/ready.c', 'int ready_value(void) { return 42; }\n');
      write(
        'ready/Ready.framework/Versions/A/Headers/Ready.h',
        'int ready_value(void);\n',
      );
      write(
        'ready/Ready.framework/Versions/A/Resources/Info.plist',
        '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>'
            '<key>CFBundleExecutable</key><string>Ready</string>'
            '<key>CFBundleIdentifier</key><string>dev.raccoon.ready</string>'
            '<key>CFBundlePackageType</key><string>FMWK</string>'
            '</dict></plist>\n',
      );
      Future<void> run(String executable, List<String> arguments) async {
        final result = await Process.run(executable, arguments);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }

      await run('xcrun', [
        'clang',
        '-dynamiclib',
        '-arch',
        'arm64',
        '-arch',
        'x86_64',
        '-install_name',
        '@rpath/Ready.framework/Versions/A/Ready',
        '-o',
        p.join(ready, 'Versions', 'A', 'Ready'),
        p.join(temp.path, 'ready', 'ready.c'),
      ]);
      for (final (link, target) in [
        ('Versions/Current', 'A'),
        ('Ready', 'Versions/Current/Ready'),
        ('Headers', 'Versions/Current/Headers'),
        ('Resources', 'Versions/Current/Resources'),
      ]) {
        Link(p.join(ready, link)).createSync(target);
      }
      await run('xcodebuild', [
        '-create-xcframework',
        '-framework',
        ready,
        '-output',
        p.join(temp.path, 'plugin_d', 'macos', 'Ready.xcframework'),
      ]);
      write(
        'plugin_d/pubspec.yaml',
        'name: plugin_d\nversion: 1.0.0\nflutter:\n  plugin:\n    platforms:\n'
            '      macos:\n        pluginClass: PluginD\n',
      );
      write(
        'plugin_d/macos/plugin_d.podspec',
        "Pod::Spec.new do |s|\n  s.name = 'plugin_d'\n  s.version = '1.0.0'\n"
            "  s.summary = 'plugin_d'\n  s.homepage = 'https://example.com'\n"
            "  s.license = { :type => 'BSD' }\n  s.author = 'Raccoon'\n"
            "  s.source = { :path => '.' }\n  s.source_files = 'Classes/**/*'\n"
            "  s.vendored_frameworks = 'Ready.xcframework'\n"
            "  s.pod_target_xcconfig = { 'OTHER_LDFLAGS' => '-framework Ready' }\n"
            "  s.dependency 'FlutterMacOS'\n  s.platform = :osx, '10.15'\nend\n",
      );
      write(
        'plugin_d/macos/Classes/PluginD.h',
        '@import FlutterMacOS;\n@interface PluginD : NSObject <FlutterPlugin>\n@end\n',
      );
      write(
        'plugin_d/macos/Classes/PluginD.m',
        '#import "PluginD.h"\n#import <Ready/Ready.h>\n@implementation PluginD\n'
            '+ (void)registerWithRegistrar:(id<FlutterPluginRegistrar>)registrar {\n'
            '  (void)ready_value();\n}\n@end\n',
      );
      write('app/pubspec.yaml', 'name: app\ndependencies:\n  plugin_d:\n');
      write(
        'app/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            {
              'name': 'plugin_d',
              'rootUri': '../../plugin_d',
              'packageUri': 'lib/',
            },
          ],
        }),
      );
      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);
      final data = p.join(temp.path, 'data');
      try {
        final result = await Process.run(
          p.join(runnerDir, 'tool', 'raccoon-device'),
          ['install', bundle.path, 'app'],
          environment: {
            'RACCOON_RUNNER': binary!,
            if (sdk != null) 'FLUTTER_ROOT': sdk,
            'XDG_DATA_HOME': data,
            'RACCOON_PLUGIN_CACHE': p.join(temp.path, 'cache'),
            'RACCOON_NO_PREBUILT': '1',
          },
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final plugins = p.join(data, 'raccoon', 'apps', 'app', 'plugins');
        final manifest =
            jsonDecode(
                  File(p.join(plugins, 'manifest.json')).readAsStringSync(),
                )
                as Map;
        expect(manifest['status'], isEmpty);
        expect(
          Directory(
            p.join(plugins, 'frameworks'),
          ).listSync().map((entry) => p.basename(entry.path)),
          containsAll(['plugin_d.framework', 'Ready.framework']),
        );
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((binary != null && sdk != null, Platform.isMacOS)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'CocoaPods plugins are macOS',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
  // pub.dev's top-level platforms: list, as isar_community_flutter_libs
  // declares it: a hosts' key of each name, with nothing under it (#92).
  const topLevelPlatforms =
      'platforms:\n  android:\n  ios:\n  linux:\n  macos:\n  windows:\n';
  Future<Map<String, Object?>> installFake(
    Directory temp,
    Map<String, String> files,
    List<String> plugins,
  ) async {
    for (final MapEntry(:key, :value) in files.entries) {
      File(p.join(temp.path, key))
        ..createSync(recursive: true)
        ..writeAsStringSync(value);
    }
    File(p.join(temp.path, 'app', 'pubspec.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'name: app\ndependencies:\n${[for (final name in plugins) '  $name:\n'].join()}',
      );
    File(p.join(temp.path, 'app', '.dart_tool', 'package_config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            for (final name in plugins)
              {'name': name, 'rootUri': '../../$name', 'packageUri': 'lib/'},
          ],
        }),
      );
    final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
      ..createSync(recursive: true);
    final data = p.join(temp.path, 'data');
    final result = await _runHelper(
      runnerDir,
      ['install', bundle.path, 'app'],
      {
        'RACCOON_RUNNER': binary ?? '',
        if (sdk != null) 'FLUTTER_ROOT': sdk,
        'XDG_DATA_HOME': data,
        'RACCOON_PLUGIN_CACHE': p.join(temp.path, 'cache'),
        'RACCOON_NO_PREBUILT': '1',
      },
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final manifest = File(
      p.join(data, 'raccoon', 'apps', 'app', 'plugins', 'manifest.json'),
    );
    expect(manifest.existsSync(), isTrue, reason: '${result.stderr}');
    return jsonDecode(manifest.readAsStringSync()) as Map<String, Object?>;
  }

  test(
    'a top-level platforms: list doesn\'t stand in for the plugin\'s own',
    () async {
      // Android only, by what flutter: plugin: says: no implementation for
      // this host, whatever the top-level list names.
      final temp = Directory.systemTemp.createTempSync('raccoon_platforms');
      addTearDown(() => temp.deleteSync(recursive: true));
      final manifest = await installFake(
        temp,
        {
          'mobile_only/pubspec.yaml':
              'name: mobile_only\nversion: 1.0.0\n$topLevelPlatforms'
              'flutter:\n  plugin:\n    platforms:\n      android:\n'
              '        package: dev.raccoon.mobile_only\n'
              '        pluginClass: MobileOnly\n',
        },
        ['mobile_only'],
      );
      expect(
        [
          for (final entry in manifest['status'] as List)
            ((entry as Map)['name'], entry['state']),
        ],
        [('mobile_only', 'no_host')],
      );
    },
    skip: switch (binary != null && sdk != null) {
      false => 'build the runner first, with a Flutter SDK on PATH',
      true => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'on Linux what only another host\'s implementation brings is not the app\'s',
    () async {
      // path_provider_android brings jni and jni_flutter, Android only: the
      // app reaches neither on Linux, so neither is blamed for a missing
      // host. One the app depends on itself still is (raccoon#16).
      final temp = Directory.systemTemp.createTempSync('raccoon_reached');
      addTearDown(() => temp.deleteSync(recursive: true));
      const android =
          '    platforms:\n      android:\n'
          '        package: dev.raccoon.x\n        pluginClass: X\n';
      final graph = jsonEncode({
        'roots': ['app'],
        'packages': [
          {
            'name': 'app',
            'dependencies': ['direct_mobile', 'mobile_impl'],
            'devDependencies': <String>[],
          },
          {'name': 'direct_mobile', 'dependencies': <String>[]},
          {
            'name': 'mobile_impl',
            'dependencies': ['mobile_helper'],
          },
          {'name': 'mobile_helper', 'dependencies': <String>[]},
        ],
        'configVersion': 1,
      });
      final files = {
        'direct_mobile/pubspec.yaml':
            'name: direct_mobile\nversion: 1.0.0\n'
            'flutter:\n  plugin:\n$android',
        'mobile_impl/pubspec.yaml':
            'name: mobile_impl\nversion: 1.0.0\n'
            'flutter:\n  plugin:\n    implements: thing\n$android',
        'mobile_helper/pubspec.yaml':
            'name: mobile_helper\nversion: 1.0.0\n'
            'flutter:\n  plugin:\n$android',
      };
      const plugins = ['direct_mobile', 'mobile_impl', 'mobile_helper'];
      List<(Object?, Object?)> states(Map<String, Object?> manifest) => [
        for (final entry in manifest['status'] as List)
          ((entry as Map)['name'], entry['state']),
      ];
      expect(
        states(
          await installFake(temp, {
            ...files,
            'app/.dart_tool/package_graph.json': graph,
          }, plugins),
        ),
        [('direct_mobile', 'no_host')],
      );
      // Without pub's graph, or with one older than the resolution, every
      // plugin counts, as before.
      for (final stale in [null, graph.replaceAll('mobile_helper', 'gone')]) {
        final again = Directory(p.join(temp.path, stale == null ? 'a' : 'b'))
          ..createSync();
        expect(
          states(
            await installFake(again, {
              ...files,
              if (stale != null) 'app/.dart_tool/package_graph.json': stale,
            }, plugins),
          ),
          unorderedEquals([
            ('direct_mobile', 'no_host'),
            ('mobile_helper', 'no_host'),
          ]),
        );
      }
    },
    skip: switch ((binary != null && sdk != null, Platform.isLinux)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'the package graph is read by the Linux half',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'on Linux camera is the runner\'s, with what it brings, and a window '
    'package that is no plugin is not',
    () async {
      // raccoon#16: camera has no desktop implementation and the runner
      // answers it, but the pane said it and its Android-only
      // flutter_plugin_android_lifecycle had none. window_manager 0.7 is no
      // plugin at all: it goes through FFI, which the runner doesn't answer.
      final temp = Directory.systemTemp.createTempSync('raccoon_own');
      addTearDown(() => temp.deleteSync(recursive: true));
      const android =
          '    platforms:\n      android:\n'
          '        package: dev.raccoon.x\n        pluginClass: X\n';
      final graph = jsonEncode({
        'roots': ['app'],
        'packages': [
          {
            'name': 'app',
            'dependencies': ['camera', 'window_manager'],
            'devDependencies': <String>[],
          },
          {
            'name': 'camera',
            'dependencies': ['flutter_plugin_android_lifecycle'],
          },
          {
            'name': 'flutter_plugin_android_lifecycle',
            'dependencies': <String>[],
          },
          {'name': 'window_manager', 'dependencies': <String>[]},
        ],
        'configVersion': 1,
      });
      final manifest = await installFake(
        temp,
        {
          'camera/pubspec.yaml':
              'name: camera\nversion: 1.0.0\nflutter:\n  plugin:\n$android',
          'flutter_plugin_android_lifecycle/pubspec.yaml':
              'name: flutter_plugin_android_lifecycle\nversion: 1.0.0\n'
              'flutter:\n  plugin:\n$android',
          'window_manager/pubspec.yaml':
              'name: window_manager\nversion: 0.7.0\n'
              'platforms:\n  linux:\n  macos:\n  windows:\n',
          'app/.dart_tool/package_graph.json': graph,
        },
        ['camera', 'flutter_plugin_android_lifecycle', 'window_manager'],
      );
      expect(
        [
          for (final entry in manifest['status'] as List)
            ((entry as Map)['name'], entry['state']),
        ],
        [('camera', 'built_in')],
      );
    },
    skip: switch ((binary != null && sdk != null, Platform.isLinux)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'the Linux half of the helper',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'on Linux a plugin that wants the view\'s window is not built or loaded',
    () async {
      // raccoon#386: bitsdojo_window_linux, flutter_window_close and
      // yaru_window_linux take their window from the registrar's view and
      // killed the runner on their first call. Left out, their calls get a
      // missing plugin's answer; a build would fail here.
      final temp = Directory.systemTemp.createTempSync('raccoon_view');
      addTearDown(() => temp.deleteSync(recursive: true));
      final manifest = await installFake(
        temp,
        {
          'bitsdojo_window_linux/pubspec.yaml':
              'name: bitsdojo_window_linux\nversion: 0.1.4\n'
              'flutter:\n  plugin:\n    platforms:\n      linux:\n'
              '        pluginClass: BitsdojoWindowPlugin\n',
          'bitsdojo_window_linux/linux/CMakeLists.txt':
              'message(FATAL_ERROR "built though it wants the view")\n',
        },
        ['bitsdojo_window_linux'],
      );
      expect(manifest['plugins'], isEmpty);
      expect(manifest['status'], [
        {
          'name': 'bitsdojo_window_linux',
          'state': 'wants_view',
          'detail':
              'no implementation on Raccoon: it wants the view\'s GTK '
              'window, and there is no view yet (#365)',
        },
      ]);
    },
    skip: switch ((binary != null && sdk != null, Platform.isLinux)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'the Linux half of the helper',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'on macOS a plugin with a top-level platforms: list is built',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_platforms');
      addTearDown(() => temp.deleteSync(recursive: true));
      final manifest = await installFake(
        temp,
        {
          'plugin_e/pubspec.yaml':
              'name: plugin_e\nversion: 1.0.0\n$topLevelPlatforms'
              'flutter:\n  plugin:\n    platforms:\n      macos:\n'
              '        pluginClass: PluginE\n',
          'plugin_e/macos/plugin_e.podspec':
              "Pod::Spec.new do |s|\n  s.name = 'plugin_e'\n"
              "  s.version = '1.0.0'\n  s.summary = 'plugin_e'\n"
              "  s.homepage = 'https://example.com'\n"
              "  s.license = { :type => 'BSD' }\n  s.author = 'Raccoon'\n"
              "  s.source = { :path => '.' }\n"
              "  s.source_files = 'Classes/**/*'\n"
              "  s.dependency 'FlutterMacOS'\n"
              "  s.platform = :osx, '10.15'\nend\n",
          'plugin_e/macos/Classes/PluginE.h':
              '@import FlutterMacOS;\n'
              '@interface PluginE : NSObject <FlutterPlugin>\n@end\n',
          'plugin_e/macos/Classes/PluginE.m':
              '#import "PluginE.h"\n@implementation PluginE\n'
              '+ (void)registerWithRegistrar:(id<FlutterPluginRegistrar>)registrar {}\n'
              '@end\n',
        },
        ['plugin_e'],
      );
      expect(manifest['status'], isEmpty);
      expect(
        [
          for (final entry in manifest['plugins'] as List)
            '${(entry as Map)['name']}',
        ],
        ['plugin_e'],
      );
    },
    skip: switch ((binary != null && sdk != null, Platform.isMacOS)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'CocoaPods plugins are macOS',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
  test(
    'on macOS a pod\'s vendored framework and library land beside it',
    () async {
      // ffmpeg_kit_flutter_new vendors plain frameworks, isar's libs a
      // dylib: CocoaPods leaves both where they are, for an app's embed
      // step to copy (#93).
      final temp = Directory.systemTemp.createTempSync('raccoon_vendored');
      addTearDown(() => temp.deleteSync(recursive: true));
      final macos = p.join(temp.path, 'plugin_f', 'macos');
      final plain = p.join(macos, 'Plain.framework');
      Directory(p.join(plain, 'Versions', 'A')).createSync(recursive: true);
      File(
        p.join(temp.path, 'plain.c'),
      ).writeAsStringSync('int plain_value(void) { return 1; }\n');
      File(
        p.join(temp.path, 'ready.c'),
      ).writeAsStringSync('int ready_value(void) { return 2; }\n');
      Future<void> run(List<String> arguments) async {
        final result = await Process.run('xcrun', arguments);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }

      await run([
        'clang',
        '-dynamiclib',
        '-arch',
        'arm64',
        '-arch',
        'x86_64',
        '-install_name',
        '@rpath/Plain.framework/Versions/A/Plain',
        '-o',
        p.join(plain, 'Versions', 'A', 'Plain'),
        p.join(temp.path, 'plain.c'),
      ]);
      Link(p.join(plain, 'Versions', 'Current')).createSync('A');
      Link(p.join(plain, 'Plain')).createSync('Versions/Current/Plain');
      await run([
        'clang',
        '-dynamiclib',
        '-arch',
        'arm64',
        '-arch',
        'x86_64',
        '-install_name',
        '@rpath/libready.dylib',
        '-o',
        p.join(macos, 'libready.dylib'),
        p.join(temp.path, 'ready.c'),
      ]);

      final manifest = await installFake(
        temp,
        {
          'plugin_f/pubspec.yaml':
              'name: plugin_f\nversion: 1.0.0\nflutter:\n  plugin:\n'
              '    platforms:\n      macos:\n        pluginClass: PluginF\n',
          'plugin_f/macos/plugin_f.podspec':
              "Pod::Spec.new do |s|\n  s.name = 'plugin_f'\n"
              "  s.version = '1.0.0'\n  s.summary = 'plugin_f'\n"
              "  s.homepage = 'https://example.com'\n"
              "  s.license = { :type => 'BSD' }\n  s.author = 'Raccoon'\n"
              "  s.source = { :path => '.' }\n"
              "  s.source_files = 'Classes/**/*'\n"
              "  s.vendored_frameworks = 'Plain.framework'\n"
              "  s.vendored_libraries = 'libready.dylib'\n"
              "  s.pod_target_xcconfig = { 'OTHER_LDFLAGS' => "
              "'-framework Plain -lready' }\n"
              "  s.dependency 'FlutterMacOS'\n"
              "  s.platform = :osx, '10.15'\nend\n",
          'plugin_f/macos/Classes/PluginF.h':
              '@import FlutterMacOS;\n'
              '@interface PluginF : NSObject <FlutterPlugin>\n@end\n',
          'plugin_f/macos/Classes/PluginF.m':
              '#import "PluginF.h"\nint plain_value(void);\n'
              'int ready_value(void);\n@implementation PluginF\n'
              '+ (void)registerWithRegistrar:(id<FlutterPluginRegistrar>)registrar {\n'
              '  (void)(plain_value() + ready_value());\n}\n@end\n',
        },
        ['plugin_f'],
      );
      expect(manifest['status'], isEmpty);
      final frameworks = Directory(
        p.join(
          temp.path,
          'data',
          'raccoon',
          'apps',
          'app',
          'plugins',
          'frameworks',
        ),
      ).listSync().map((entry) => p.basename(entry.path));
      expect(
        frameworks,
        containsAll([
          'plugin_f.framework',
          'Plain.framework',
          'libready.dylib',
        ]),
      );
    },
    skip: switch ((binary != null && sdk != null, Platform.isMacOS)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'CocoaPods plugins are macOS',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
  test(
    'a pub workspace member gets its own plugins, not the other members\'',
    () async {
      // A member has no package config of its own; the workspace root's
      // names every member's packages. Each member here depends on a plugin
      // with no desktop implementation, which the helper reports without
      // building anything: the report should name the app's, not the
      // other member's.
      final temp = Directory.systemTemp.createTempSync('raccoon_workspace');
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      String androidOnly(String name) =>
          'name: $name\n'
          'flutter:\n'
          '  plugin:\n'
          '    platforms:\n'
          '      android:\n'
          '        package: dev.raccoon.$name\n'
          '        pluginClass: Plugin\n';
      write(
        'pubspec.yaml',
        'name: _workspace\nworkspace:\n  - app\n  - other\n',
      );
      write(
        'app/pubspec.yaml',
        'name: app\nresolution: workspace\ndependencies:\n  app_plugin:\n',
      );
      write(
        'other/pubspec.yaml',
        'name: other\nresolution: workspace\ndependencies:\n  other_plugin:\n',
      );
      write('app_plugin/pubspec.yaml', androidOnly('app_plugin'));
      write('other_plugin/pubspec.yaml', androidOnly('other_plugin'));
      write(
        '.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            for (final name in ['app', 'other', 'app_plugin', 'other_plugin'])
              {'name': name, 'rootUri': '../$name', 'packageUri': 'lib/'},
          ],
        }),
      );
      write(
        '.dart_tool/package_graph.json',
        jsonEncode({
          'configVersion': 1,
          'roots': ['app', 'other'],
          'packages': [
            {
              'name': 'app',
              'dependencies': ['app_plugin'],
            },
            {
              'name': 'other',
              'dependencies': ['other_plugin'],
            },
            {'name': 'app_plugin', 'dependencies': <String>[]},
            {'name': 'other_plugin', 'dependencies': <String>[]},
          ],
        }),
      );
      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);
      final data = p.join(temp.path, 'data');
      final cache = p.join(temp.path, 'cache');
      // package_scope.dart runs from a kernel snapshot kept in the cache
      // (#328); one that won't load is dropped, and the script runs as is.
      File snapshot() => File(
        p.join(
          cache,
          'raccoon',
          'tools',
          File(
            p.join(sdk!, 'bin', 'cache', 'dart-sdk', 'version'),
          ).readAsStringSync().trim(),
          'package_scope.dill',
        ),
      );
      Future<void> installs() async {
        // On Windows through Git Bash, with the forward slashes the
        // helper's paths have there.
        String posix(String path) => path.replaceAll(r'\', '/');
        final install = await Process.run(
          CustomDeviceConfig.hostLauncher.firstOrNull ??
              p.join(runnerDir, 'tool', 'raccoon-device'),
          [
            if (CustomDeviceConfig.hostLauncher.isNotEmpty)
              posix(p.join(runnerDir, 'tool', 'raccoon-device')),
            'install',
            posix(bundle.path),
            'app',
          ],
          environment: {
            'RACCOON_RUNNER': posix(binary!),
            if (sdk != null) 'FLUTTER_ROOT': posix(sdk),
            'XDG_DATA_HOME': posix(data),
            'XDG_CACHE_HOME': posix(cache),
          },
        );
        expect(install.exitCode, 0, reason: '${install.stderr}');
        final manifest = File(
          p.join(data, 'raccoon', 'apps', 'app', 'plugins', 'manifest.json'),
        );
        expect(manifest.existsSync(), isTrue, reason: '${install.stderr}');
        final status = [
          for (final entry
              in (jsonDecode(manifest.readAsStringSync()) as Map)['status']
                  as List)
            '${(entry as Map)['name']}',
        ];
        expect(status, ['app_plugin']);
      }

      try {
        await installs();
        expect(snapshot().existsSync(), isTrue);
        snapshot().writeAsBytesSync(
          snapshot().readAsBytesSync().sublist(0, 100),
        );
        await installs();
        expect(snapshot().existsSync(), isFalse);
        await installs();
        expect(snapshot().existsSync(), isTrue);
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch (binary != null && sdk != null) {
      false => 'build the runner first, with a Flutter SDK on PATH',
      true => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'RACCOON_PLUGINS=cached builds nothing, off has no plugins',
    () async {
      // #214: plugins_app's echo plugin, with an empty cache and no
      // prebuilt archive: cached leaves it out and says so, off has none,
      // and once built, cached takes it.
      final temp = Directory.systemTemp.createTempSync('raccoon_plugins');
      final data = p.join(temp.path, 'data');
      final out = p.join(data, 'raccoon', 'apps', 'plugins_app', 'plugins');
      Future<String> install(String? mode, {bool pods = false}) async {
        final result = await _runHelper(
          runnerDir,
          ['install', pluginsAppAssets, 'plugins_app'],
          {
            'RACCOON_RUNNER': binary!,
            if (sdk != null) 'FLUTTER_ROOT': sdk,
            'XDG_DATA_HOME': data,
            'XDG_RUNTIME_DIR': temp.path,
            'TMPDIR': '${temp.path}/',
            'RACCOON_PLUGIN_CACHE': p.join(temp.path, 'cache'),
            'RACCOON_NO_PREBUILT': '1',
            if (mode != null) 'RACCOON_PLUGINS': mode,
            if (pods) 'RACCOON_NO_SWIFT_PACKAGES': '1',
          },
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        return '${result.stderr}';
      }

      Map<String, String> states() {
        final manifest =
            jsonDecode(File(p.join(out, 'manifest.json')).readAsStringSync())
                as Map;
        return {
          for (final entry in (manifest['status'] as List).cast<Map>())
            '${entry['name']}': '${entry['state']}',
          for (final entry in (manifest['plugins'] as List).cast<Map>())
            '${entry['name']}': 'loaded',
        };
      }

      try {
        expect(await install('off'), contains('native plugins off'));
        expect(File(p.join(out, 'manifest.json')).existsSync(), isFalse);

        expect(
          await install('cached'),
          contains('1 not built (RACCOON_PLUGINS=cached): raccoon_echo'),
        );
        expect(states(), {'raccoon_echo': 'skipped'});
        expect(
          Directory(p.join(temp.path, 'cache', 'failed')).existsSync(),
          isFalse,
        );

        expect(await install('build'), contains('1 built: raccoon_echo'));
        expect(
          await install('cached'),
          contains('1 from the cache: raccoon_echo'),
        );
        expect(states(), {'raccoon_echo': 'loaded'});

        if (Platform.isMacOS) {
          // #225: a CocoaPods entry records the keys of the plugins it
          // carries; one recorded with a key this app's plugin no longer
          // has is built again.
          expect(
            await install('build', pods: true),
            contains('1 built: raccoon_echo'),
          );
          final record = Directory(p.join(temp.path, 'cache'))
              .listSync(recursive: true)
              .whereType<File>()
              .singleWhere(
                (file) =>
                    p.basename(file.path) == '.plugins.json' &&
                    p.basename(file.parent.path).startsWith('raccoon_echo-'),
              );
          expect(record.readAsStringSync(), '{}');
          record.writeAsStringSync('{"raccoon_echo": "an older key"}');
          expect(
            await install('cached', pods: true),
            contains('1 not built (RACCOON_PLUGINS=cached): raccoon_echo'),
          );
          expect(
            await install('build', pods: true),
            contains('1 built: raccoon_echo'),
          );
          expect(record.readAsStringSync(), '{}');
        }

        // Where the environment says none, the host's default, then the
        // app's own over it; the environment's wins over both.
        final saved = AppPlugins(p.join(data, 'raccoon', 'data'));
        saved.saveDefault(NativePlugins.off);
        expect(await install(null), contains('native plugins off'));
        // An app's file that says none of the three is passed over.
        File(p.join(data, 'raccoon', 'data', 'plugins_app', 'plugins'))
          ..createSync(recursive: true)
          ..writeAsStringSync('sometimes\n');
        expect(await install(null), contains('native plugins off'));
        saved.save('plugins_app', NativePlugins.cached);
        expect(await install(null), contains('1 from the cache: raccoon_echo'));
        saved.save('plugins_app', NativePlugins.off);
        expect(
          await install('cached'),
          contains('1 from the cache: raccoon_echo'),
        );
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch (binary != null &&
        sdk != null &&
        Directory(pluginsAppAssets).existsSync()) {
      false => 'build the runner and example/plugins_app first',
      true => false,
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
  test(
    'on macOS a plugin with a Swift package is built through it and answers',
    () async {
      // #187: example/plugins/echo has a Package.swift beside its podspec,
      // as Flutter's plugin template makes one; the helper builds it with
      // the app's other Swift packages into one framework.
      final temp = Directory.systemTemp.createTempSync('raccoon_swiftpm');
      final helper = p.join(runnerDir, 'tool', 'raccoon-device');
      final data = p.join(temp.path, 'data');
      Map<String, String> environment({bool pods = false}) => {
        'RACCOON_RUNNER': binary!,
        if (sdk != null) 'FLUTTER_ROOT': sdk,
        'XDG_DATA_HOME': data,
        'XDG_RUNTIME_DIR': temp.path,
        'TMPDIR': '${temp.path}/',
        'RACCOON_PLUGIN_CACHE': p.join(temp.path, 'cache'),
        'RACCOON_NO_PREBUILT': '1',
        if (pods) 'RACCOON_NO_SWIFT_PACKAGES': '1',
      };
      Future<(String, String)> install({bool pods = false}) async {
        final result = await Process.run(helper, [
          'install',
          pluginsAppAssets,
          'plugins_app',
        ], environment: environment(pods: pods));
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final manifest =
            jsonDecode(
                  File(
                    p.join(
                      data,
                      'raccoon',
                      'apps',
                      'plugins_app',
                      'plugins',
                      'manifest.json',
                    ),
                  ).readAsStringSync(),
                )
                as Map;
        final echo = (manifest['plugins'] as List).cast<Map>().singleWhere(
          (entry) => entry['name'] == 'raccoon_echo',
        );
        return ('${result.stderr}', '${echo['library']}');
      }

      try {
        final (built, library) = await install();
        expect(built, contains('1 built: raccoon_echo'));
        expect(library, endsWith('RaccoonPlugins.framework/RaccoonPlugins'));
        // Checkouts stay for the next build (#188).
        expect(
          Directory(p.join(temp.path, 'cache', 'swiftpm-sources')).existsSync(),
          isTrue,
        );
        final run = await Process.start(helper, [
          'run',
          'plugins_app',
        ], environment: environment());
        final lines = <String>[];
        run.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(lines.add);
        run.stderr.drain<void>().ignore();
        try {
          final deadline = DateTime.now().add(const Duration(seconds: 30));
          while (!lines.any((line) => line.contains('ECHO:')) &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(lines, contains('ECHO:echo: hello'));
        } finally {
          run.kill();
          await run.exitCode;
        }

        final (again, _) = await install();
        expect(again, contains('1 from the cache: raccoon_echo'));
        // Turned off, the podspec builds it as before.
        final (_, pods) = await install(pods: true);
        expect(pods, endsWith('raccoon_echo.framework/raccoon_echo'));
        // Every one of them a pod in the cache (the release's prebuilt
        // plugins): those, rather than a build.
        for (final entry in Directory(p.join(temp.path, 'cache')).listSync()) {
          if (p.basename(entry.path).startsWith('swiftpm-')) {
            entry.deleteSync(recursive: true);
          }
        }
        final (cached, podLibrary) = await install();
        expect(cached, contains('1 from the cache: raccoon_echo'));
        expect(podLibrary, endsWith('raccoon_echo.framework/raccoon_echo'));

        // The release's prebuilt plugins are one pod each, which an install
        // can take; never a build of a whole set (#189).
        final archive = p.join(temp.path, 'prebuilt.tar.gz');
        final prebuild = await Process.run(helper, [
          'prebuild',
          p.dirname(p.dirname(pluginsAppAssets)),
          archive,
        ], environment: environment());
        expect(prebuild.exitCode, 0, reason: '${prebuild.stderr}');
        final listing =
            '${(await Process.run('tar', ['tzf', archive])).stdout}';
        expect(listing, contains('raccoon_echo.framework/'));
        expect(listing, isNot(contains('swiftpm-')));
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((
      binary != null && sdk != null && Directory(pluginsAppAssets).existsSync(),
      Platform.isMacOS,
    )) {
      (false, _) => 'build the runner and example/plugins_app first',
      (_, false) => 'Swift packages are a macOS build',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

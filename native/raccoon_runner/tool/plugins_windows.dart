// The Windows half of raccoon-device's build_plugins, in Dart: Windows has
// no python3, and every Flutter SDK has dart. Run with the SDK's dart, no
// package of its own, so dart: libraries only.
//
//   dart plugins_windows.dart <package_config.json> <out> <virtual plugins>
//       <cache> <runner version> <sdk windows-x64 artifacts>
//
// The resolved packages whose pubspec names a Windows pluginClass
// (registered) or ffiPlugin (its libraries only), as the Flutter tool finds
// them. What built before is in a cache by plugin version and runner
// version; the rest builds here, each plugin in its own CMake project with
// what Flutter's Windows template gives a plugin (flutter, the C++ client
// wrapper as flutter_wrapper_plugin, apply_standard_settings, UNICODE),
// against the SDK's import library, in Visual Studio's x64 developer
// environment. Every DLL lands flat in <out>/lib, which run puts on the
// PATH for the FFI ones; <out>/manifest.json names each plugin's DLL and
// its <PluginClass>RegisterWithRegistrar for the runner.
//
// A plugin built as a static library (FlutterFire's) is linked into an app's
// .exe, which the runner has none of to give it. The app's static plugins
// are built together in one project, a plugin after those whose targets it
// links, and linked into one DLL that exports their registrars
// (raccoon_static_plugins.dll): one module, as in the .exe, so plugins that
// share state, such as firebase_core's app, keep sharing it (#104).

import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final watch = Stopwatch()..start();
  if (arguments.length != 6) {
    stderr.writeln(
      'usage: plugins_windows.dart <package_config.json> <out> <virtual> '
      '<cache> <runner version> <sdk windows-x64 dir>',
    );
    exitCode = 2;
    return;
  }
  final [config, out, virtualList, cache, runnerVersion, engine] = arguments;
  final virtual = virtualList.split(' ').where((n) => n.isNotEmpty).toSet();
  final dartTool = File(config).parent.path;

  final packages = <({String name, String root, String pubspec})>[];
  final decoded = jsonDecode(File(config).readAsStringSync()) as Map;
  for (final package in (decoded['packages'] as List? ?? const [])) {
    final uri = '${package['rootUri'] ?? ''}';
    final root = uri.startsWith('file://')
        ? Uri.parse(uri).toFilePath()
        : File('$dartTool/$uri').absolute.path;
    final pubspec = File('$root${Platform.pathSeparator}pubspec.yaml');
    if (!pubspec.existsSync()) continue;
    packages.add((
      name: '${package['name']}',
      root: Directory(root).absolute.path,
      pubspec: pubspec.readAsStringSync(),
    ));
  }

  // Implementation packages of federated plugins: named as a default_package
  // by their app-facing package, or saying what they implement. Not the ones
  // to blame for a missing host.
  final implementations = <String>{
    for (final package in packages)
      for (final match in RegExp(
        r'default_package:\s*(\w+)',
      ).allMatches(package.pubspec))
        match.group(1) ?? '',
  };

  final wanted = <_Plugin>[];
  // What never gets as far as a library, for the runner to relay.
  final status = <Map<String, String>>[];
  for (final package in packages) {
    if (virtual.contains(package.name)) {
      status.add({
        'name': package.name,
        'state': 'built_in',
        'detail': 'the runner answers it',
      });
      continue;
    }
    final found = RegExp(
      r'^\s+plugin:\s*$',
      multiLine: true,
    ).firstMatch(package.pubspec);
    if (found == null) continue;
    // Only what flutter: plugin: says: pub.dev's top-level platforms: list
    // names hosts too, with nothing under them (#92).
    final plugin = package.pubspec.substring(found.end);
    final block = _windowsBlock(plugin);
    final pluginClass = RegExp(r'pluginClass:\s*(\w+)')
        .firstMatch(block)
        ?.group(1);
    final ffi = RegExp(r'ffiPlugin:\s*true').hasMatch(block);
    if (pluginClass == null && !ffi) {
      // An app-facing plugin with no Windows at all: the app's calls to it
      // will fail, and the pane can say so before they do.
      if (block.isEmpty &&
          RegExp(r'^\s+platforms:\s*$', multiLine: true).hasMatch(plugin) &&
          !RegExp(r'^\s+windows:', multiLine: true).hasMatch(plugin) &&
          !RegExp(r'^\s+implements:', multiLine: true).hasMatch(plugin) &&
          !implementations.contains(package.name)) {
        status.add({
          'name': package.name,
          'state': 'no_host',
          'detail': 'no Windows implementation',
        });
      }
      continue;
    }
    final cmake = File('${package.root}\\windows\\CMakeLists.txt');
    if (!cmake.existsSync()) continue;
    final cmakeText = cmake.readAsStringSync();
    wanted.add(
      _Plugin(
        name: package.name,
        root: package.root,
        symbol: pluginClass == null
            ? null
            : '${pluginClass}RegisterWithRegistrar',
        key: '${_versionKey(package.name, package.root)}-$runnerVersion',
        cmake: cmakeText,
        isStatic: RegExp(r'add_library\(\s*\$\{PLUGIN_NAME\}\s+STATIC\b')
            .hasMatch(cmakeText),
      ),
    );
  }
  if (wanted.isEmpty && status.isEmpty) return;

  final lib = Directory('$out\\lib')..createSync(recursive: true);
  final built = <String>[];
  final failed = <String>[];
  final empty = <String>[];
  final fromCache = <String>[];
  final entries = <Map<String, String>>[];
  Map<String, String>? toolchain;
  String? noToolchain;
  Future<Map<String, String>?> needToolchain() async {
    if (toolchain == null && noToolchain == null) {
      try {
        toolchain = await _msvcEnvironment();
      } on _NoToolchain catch (error) {
        noToolchain = error.message;
      }
    }
    return toolchain;
  }

  for (final plugin in wanted) {
    if (plugin.isStatic) continue;
    final cached = Directory('$cache\\${plugin.key}');
    var dlls = _dllsIn(cached);
    if (dlls.isNotEmpty) {
      fromCache.add(plugin.name);
    } else {
      final environment = await needToolchain();
      if (environment == null) {
        failed.add('${plugin.name} ($noToolchain)');
        status.add({
          'name': plugin.name,
          'state': 'failed',
          'detail': '$noToolchain; native plugins need Visual Studio',
        });
        continue;
      }
      final project = Directory('$out\\build\\${plugin.name}')
        ..createSync(recursive: true);
      File('${project.path}\\CMakeLists.txt').writeAsStringSync(
        '${_preamble(engine)}'
        'add_subdirectory("${_cmakePath('${plugin.root}\\windows')}" "plugin")\n'
        '# What the plugin bundles beside itself, for the runner to find.\n'
        'file(WRITE "\${CMAKE_BINARY_DIR}/bundled.txt" '
        '"\${${plugin.name}_bundled_libraries}")\n',
      );
      final log = File('${project.path}\\build.log');
      // Visual Studio's own generator, CMake's default here, as the Flutter
      // tool builds Windows apps: some plugins hand MSBuild a NuGet
      // package's .targets file, which no other generator reads.
      final ok =
          await _run(environment, log, [
            '-S',
            project.path,
            '-B',
            '${project.path}\\out',
            '-A',
            'x64',
          ]) &&
          await _run(environment, log, [
            '--build',
            '${project.path}\\out',
            '--config',
            'Release',
          ]);
      if (!ok) {
        failed.add('${plugin.name} (see ${log.path})');
        status.add({
          'name': plugin.name,
          'state': 'failed',
          'detail': 'did not build; see ${log.path}',
        });
        continue;
      }
      final made = [
        ..._dllsIn(Directory('${project.path}\\out\\plugin')),
        ..._bundled(File('${project.path}\\out\\bundled.txt')),
      ];
      if (made.isEmpty) {
        // Built fine and made nothing: an FFI plugin whose library wants
        // a toolchain this machine has not.
        empty.add(plugin.name);
        status.add({
          'name': plugin.name,
          'state': 'built_nothing',
          'detail': 'built and made no library',
        });
        continue;
      }
      cached.createSync(recursive: true);
      for (final dll in made) {
        dll.copySync('${cached.path}\\${_basename(dll.path)}');
      }
      dlls = _dllsIn(cached);
      built.add(plugin.name);
    }
    for (final dll in dlls) {
      dll.copySync('${lib.path}\\${_basename(dll.path)}');
    }
    final symbol = plugin.symbol;
    if (symbol == null) continue;
    // The plugin's own library is the one named after it.
    final own = dlls.where(
      (dll) => _basename(dll.path).toLowerCase() == '${plugin.name}_plugin.dll',
    );
    final main = own.isEmpty ? dlls.first : own.first;
    entries.add({
      'name': plugin.name,
      'library': '${lib.path}\\${_basename(main.path)}',
      'symbol': symbol,
    });
  }

  final statics = _linkOrder(wanted.where((p) => p.isStatic).toList());
  if (statics.isNotEmpty) {
    final names = statics.map((p) => p.name).toList();
    final key = _hash(
      'raccoon_static_plugins',
      (statics.map((p) => p.key).toList()..sort()).join('\n'),
    );
    final cached = Directory('$cache\\$key');
    var dlls = _dllsIn(cached);
    String? whyNot;
    if (dlls.isNotEmpty) {
      fromCache.addAll(names);
    } else {
      final environment = await needToolchain();
      if (environment == null) {
        whyNot = '$noToolchain; native plugins need Visual Studio';
      } else {
        final project = Directory('$out\\build\\raccoon_static_plugins')
          ..createSync(recursive: true);
        final symbols = [
          for (final plugin in statics)
            if (plugin.symbol case final symbol?) symbol,
        ];
        final def = File('${project.path}\\raccoon_static_plugins.def')
          ..writeAsStringSync(
            'LIBRARY raccoon_static_plugins\nEXPORTS\n'
            '${symbols.map((symbol) => '  $symbol\n').join()}',
          );
        File('${project.path}\\CMakeLists.txt').writeAsStringSync(
          '${_preamble(engine)}'
          '${statics.map((plugin) => 'add_subdirectory("${_cmakePath('${plugin.root}\\windows')}" "${plugin.name}")\n').join()}'
          '# One module for them all, as the .exe they were made for; the\n'
          '# .def file exports their registrars from the static libraries.\n'
          'file(WRITE "\${CMAKE_BINARY_DIR}/raccoon_static_plugins.cc" "")\n'
          'add_library(raccoon_static_plugins SHARED '
          '"\${CMAKE_BINARY_DIR}/raccoon_static_plugins.cc" '
          '"${_cmakePath(def.path)}")\n'
          'target_link_libraries(raccoon_static_plugins PRIVATE '
          '${statics.map((plugin) => '${plugin.name}_plugin').join(' ')})\n'
          'set_target_properties(raccoon_static_plugins PROPERTIES '
          'RUNTIME_OUTPUT_DIRECTORY "\${CMAKE_BINARY_DIR}/plugin")\n'
          'file(WRITE "\${CMAKE_BINARY_DIR}/bundled.txt" '
          '"${statics.map((plugin) => '\${${plugin.name}_bundled_libraries}').join(';')}")\n',
        );
        final log = File('${project.path}\\build.log');
        final ok =
            await _run(environment, log, [
              '-S',
              project.path,
              '-B',
              '${project.path}\\out',
              '-A',
              'x64',
            ]) &&
            await _run(environment, log, [
              '--build',
              '${project.path}\\out',
              '--config',
              'Release',
              '--target',
              'raccoon_static_plugins',
            ]);
        final made = [
          ..._dllsIn(Directory('${project.path}\\out\\plugin')),
          ..._bundled(File('${project.path}\\out\\bundled.txt')),
        ];
        if (!ok || made.isEmpty) {
          whyNot = 'did not build; see ${log.path}';
        } else {
          cached.createSync(recursive: true);
          for (final dll in made) {
            dll.copySync('${cached.path}\\${_basename(dll.path)}');
          }
          dlls = _dllsIn(cached);
          built.addAll(names);
        }
      }
    }
    if (whyNot != null) {
      failed.add('${names.join(', ')} ($whyNot)');
      for (final name in names) {
        status.add({'name': name, 'state': 'failed', 'detail': whyNot});
      }
    } else {
      for (final dll in dlls) {
        dll.copySync('${lib.path}\\${_basename(dll.path)}');
      }
      for (final plugin in statics) {
        final symbol = plugin.symbol;
        if (symbol == null) continue;
        entries.add({
          'name': plugin.name,
          'library': '${lib.path}\\raccoon_static_plugins.dll',
          'symbol': symbol,
        });
      }
    }
  }

  File('$out\\manifest.json').writeAsStringSync(
    const JsonEncoder.withIndent(
      ' ',
    ).convert({'plugins': entries, 'status': status, 'library_path': lib.path}),
  );
  final parts = [
    if (built.isNotEmpty) '${built.length} built: ${built.join(', ')}',
    if (fromCache.isNotEmpty)
      '${fromCache.length} from the cache: ${fromCache.join(', ')}',
    if (empty.isNotEmpty) '${empty.length} built nothing: ${empty.join(', ')}',
    if (failed.isNotEmpty) '${failed.length} failed: ${failed.join('; ')}',
  ];
  stderr.writeln(
    '🦝 native plugins ready in '
    '${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s: '
    '${parts.isEmpty ? 'none to build' : parts.join('; ')}',
  );
}

final class _Plugin {
  const _Plugin({
    required this.name,
    required this.root,
    required this.symbol,
    required this.key,
    required this.cmake,
    required this.isStatic,
  });

  final String name;
  final String root;

  /// `<PluginClass>RegisterWithRegistrar`, or null for an FFI plugin.
  final String? symbol;

  /// Its directory in the cache: plugin version and runner version.
  final String key;

  /// Its windows/CMakeLists.txt.
  final String cmake;

  /// Whether that builds it as a static library, for an .exe to link.
  final bool isStatic;
}

/// [plugins] with each after the others whose `<name>_plugin` target it
/// links: firebase_core before the FlutterFire plugins built on it.
List<_Plugin> _linkOrder(List<_Plugin> plugins) {
  final ordered = <_Plugin>[];
  final placed = <String>{};
  void place(_Plugin plugin, Set<String> visiting) {
    if (placed.contains(plugin.name) || !visiting.add(plugin.name)) return;
    for (final other in plugins) {
      if (other.name != plugin.name &&
          plugin.cmake.contains('${other.name}_plugin')) {
        place(other, visiting);
      }
    }
    placed.add(plugin.name);
    ordered.add(plugin);
  }

  for (final plugin in plugins) {
    place(plugin, <String>{});
  }
  return ordered;
}

final class _NoToolchain implements Exception {
  const _NoToolchain(this.message);

  final String message;
}

/// The lines under the pubspec's `windows:` key, more indented than it.
String _windowsBlock(String pubspec) {
  final found = RegExp(
    r'^([ \t]*)windows:[ \t]*\r?\n',
    multiLine: true,
  ).firstMatch(pubspec);
  if (found == null) return '';
  final indent = (found.group(1) ?? '').length;
  final block = <String>[];
  for (final line in const LineSplitter().convert(
    pubspec.substring(found.end),
  )) {
    if (line.trim().isEmpty) continue;
    if (line.length - line.trimLeft().length <= indent) break;
    block.add(line);
  }
  return block.join('\n');
}

/// A hosted package is its directory name, name-version; a path package is
/// the shape of its windows/ directory, so an edit rebuilds it.
String _versionKey(String name, String root) {
  final segments = root.split(RegExp(r'[\\/]'));
  if (segments.contains('hosted'))
    return segments.lastWhere((s) => s.isNotEmpty);
  final windows = Directory('$root\\windows');
  final shape = StringBuffer();
  final files = windows.listSync(recursive: true).whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final stat = file.statSync();
    shape.writeln(
      '${file.path.substring(root.length)} ${stat.size} '
      '${stat.modified.millisecondsSinceEpoch ~/ 1000}',
    );
  }
  return _hash('$name-path', shape.toString());
}

/// [prefix] and a hash of [text]: FNV-1a, 64 bits, as dart: has no hash of
/// its own to offer here.
String _hash(String prefix, String text) {
  var hash = 0xcbf29ce484222325;
  for (final unit in utf8.encode(text)) {
    hash = ((hash ^ unit) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return '$prefix-${hash.toUnsigned(64).toRadixString(16).padLeft(16, '0')}';
}

/// What Flutter's Windows template gives a plugin: the root's UNICODE, the
/// flutter library over the SDK's import library and headers, the C++
/// client wrapper as flutter_wrapper_plugin, apply_standard_settings.
String _preamble(String engine) {
  final sdk = _cmakePath(engine);
  final wrapper = '$sdk/cpp_client_wrapper';
  return '''
cmake_minimum_required(VERSION 3.14)
project(raccoon_plugin LANGUAGES CXX)
set(CMAKE_CONFIGURATION_TYPES Release)
add_definitions(-DUNICODE -D_UNICODE)
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(\${TARGET} PUBLIC cxx_std_17)
  target_compile_options(\${TARGET} PRIVATE /W4 /WX /wd4100)
  target_compile_options(\${TARGET} PRIVATE /EHsc)
  target_compile_definitions(\${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(\${TARGET} PRIVATE "\$<\$<CONFIG:Debug>:_DEBUG>")
endfunction()
add_library(flutter INTERFACE)
target_include_directories(flutter INTERFACE "$sdk")
target_link_libraries(flutter INTERFACE "$sdk/flutter_windows.dll.lib")
add_library(flutter_wrapper_plugin STATIC
  "$wrapper/core_implementations.cc"
  "$wrapper/standard_codec.cc"
  "$wrapper/plugin_registrar.cc")
apply_standard_settings(flutter_wrapper_plugin)
set_target_properties(flutter_wrapper_plugin PROPERTIES
  POSITION_INDEPENDENT_CODE ON CXX_VISIBILITY_PRESET hidden)
target_link_libraries(flutter_wrapper_plugin PUBLIC flutter)
target_include_directories(flutter_wrapper_plugin PUBLIC "$wrapper/include")
''';
}

/// The environment of Visual Studio's x64 developer prompt: vcvars64.bat
/// of the newest install with the C++ tools, as vswhere finds it.
Future<Map<String, String>> _msvcEnvironment() async {
  final programs =
      Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
  final vswhere = '$programs\\Microsoft Visual Studio\\Installer\\vswhere.exe';
  if (!File(vswhere).existsSync()) {
    throw const _NoToolchain('no Visual Studio');
  }
  final found = await Process.run(vswhere, const [
    '-latest',
    '-products',
    '*',
    '-requires',
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
    '-property',
    'installationPath',
  ]);
  final install = '${found.stdout}'.trim();
  if (install.isEmpty) {
    throw const _NoToolchain('no Visual Studio with the C++ tools');
  }
  final vcvars = '$install\\VC\\Auxiliary\\Build\\vcvars64.bat';
  final set = await Process.run('cmd', [
    '/c',
    'call',
    vcvars,
    '>nul',
    '&&',
    'set',
  ]);
  if (set.exitCode != 0) throw const _NoToolchain('vcvars64.bat failed');
  final environment = <String, String>{};
  for (final line in const LineSplitter().convert('${set.stdout}')) {
    final at = line.indexOf('=');
    if (at <= 0) continue;
    final name = line.substring(0, at);
    environment[name.toUpperCase() == 'PATH' ? 'PATH' : name] = line.substring(
      at + 1,
    );
  }
  return environment;
}

/// Runs Visual Studio's cmake with [arguments], its output into [log].
/// Windows looks a program up on this process's PATH, not the one it is
/// given, so cmake is named by its path in [environment].
Future<bool> _run(
  Map<String, String> environment,
  File log,
  List<String> arguments,
) async {
  final cmake = (environment['PATH'] ?? '')
      .split(';')
      .where((directory) => directory.isNotEmpty)
      .map((directory) => '$directory\\cmake.exe')
      .firstWhere((path) => File(path).existsSync(), orElse: () => 'cmake');
  final result = await Process.run(cmake, arguments, environment: environment);
  log.writeAsStringSync(
    '\$ cmake ${arguments.join(' ')}\n${result.stdout}${result.stderr}',
    mode: FileMode.append,
  );
  return result.exitCode == 0;
}

List<File> _dllsIn(Directory directory) {
  if (!directory.existsSync()) return const [];
  return directory
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.toLowerCase().endsWith('.dll'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

/// The DLLs a plugin's CMake names in its <name>_bundled_libraries.
List<File> _bundled(File list) {
  if (!list.existsSync()) return const [];
  return [
    for (final path in list.readAsStringSync().split(';'))
      if (path.trim().toLowerCase().endsWith('.dll') &&
          File(path.trim()).existsSync())
        File(path.trim()),
  ];
}

String _basename(String path) => path.split(RegExp(r'[\\/]')).last;

/// A path as CMake writes it, with forward slashes.
String _cmakePath(String path) => path.replaceAll('\\', '/');

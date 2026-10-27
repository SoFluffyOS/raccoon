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
  // Where pub may keep packages: PUB_CACHE, its default, or the Flutter
  // SDK's own .pub-cache, which the tool picks when it is there. The SDK is
  // five levels above its windows-x64 artifacts.
  final pubCaches = [
    if (Platform.environment['PUB_CACHE'] case final set?) set,
    '${Platform.environment['LOCALAPPDATA'] ?? ''}\\Pub\\Cache',
    '${Directory(engine).parent.parent.parent.parent.parent.path}\\.pub-cache',
  ];

  final packages = <({String name, String root, String pubspec})>[];
  final decoded = jsonDecode(File(config).readAsStringSync()) as Map;
  for (final package in (decoded['packages'] as List? ?? const [])) {
    final uri = '${package['rootUri'] ?? ''}';
    final root = uri.startsWith('file://')
        ? Uri.parse(uri).toFilePath()
        // pub writes a relative URI encoded: my%20libs for my libs (#120).
        : File('$dartTool/${Uri.decodeFull(uri)}').absolute.path;
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
    if (!File('${package.root}\\windows\\CMakeLists.txt').existsSync()) {
      continue;
    }
    wanted.add(
      _Plugin(
        name: package.name,
        root: package.root,
        symbol: pluginClass == null
            ? null
            : '${pluginClass}RegisterWithRegistrar',
        key:
            '${_versionKey(package.name, package.root, pubCaches)}'
            '-$runnerVersion',
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
  for (final plugin in wanted) {
    // Whatever else goes wrong fails this plugin, not the install: the
    // helper runs under set -e, and native assets build after (#141).
    try {
      final cached = Directory('$cache\\${plugin.key}');
      var dlls = _dllsIn(cached);
      if (dlls.isNotEmpty) {
        fromCache.add(plugin.name);
      } else {
        if (toolchain == null && noToolchain == null) {
          try {
            toolchain = await _msvcEnvironment();
          } on _NoToolchain catch (error) {
            noToolchain = error.message;
          }
        }
        final environment = toolchain;
        if (environment == null) {
          failed.add('${plugin.name} ($noToolchain)');
          status.add({
            'name': plugin.name,
            'state': 'failed',
            'detail': '$noToolchain; native plugins need Visual Studio',
          });
          continue;
        }
        if (_keptFailure(cache, plugin, environment) case final why?) {
          failed.add('${plugin.name} ($why)');
          status.add({'name': plugin.name, 'state': 'failed', 'detail': why});
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
          final why = _keepFailure(
            cache,
            plugin,
            environment,
            'did not build; see ${log.path}',
            log,
          );
          failed.add('${plugin.name} (see ${log.path})');
          status.add({'name': plugin.name, 'state': 'failed', 'detail': why});
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
        // Staged aside and renamed into place, as on the other hosts
        // (#136): an install that stops halfway leaves no entry, and two at
        // once never share a half-copied one.
        final staging = Directory('${cached.path}.partial-$pid')
          ..createSync(recursive: true);
        for (final dll in made) {
          dll.copySync('${staging.path}\\${_basename(dll.path)}');
        }
        _settle(staging, cached);
        dlls = _dllsIn(cached);
        // A rename the system refused: the build's own.
        if (dlls.isEmpty) dlls = made;
        built.add(plugin.name);
      }
      for (final dll in dlls) {
        dll.copySync('${lib.path}\\${_basename(dll.path)}');
      }
      final symbol = plugin.symbol;
      if (symbol == null) continue;
      // The plugin's own library is the one named after it.
      final own = dlls.where(
        (dll) =>
            _basename(dll.path).toLowerCase() == '${plugin.name}_plugin.dll',
      );
      final main = own.isEmpty ? dlls.first : own.first;
      entries.add({
        'name': plugin.name,
        'library': '${lib.path}\\${_basename(main.path)}',
        'symbol': symbol,
      });
    } on Exception catch (error) {
      failed.add('${plugin.name} ($error)');
      status.add({'name': plugin.name, 'state': 'failed', 'detail': '$error'});
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

// A plugin that failed to build is kept failed, as on the other hosts
// (#136): by its key and Visual Studio's tools, for a day, its log beside
// it; never with RACCOON_RETRY_PLUGINS=1, and never for a missing
// toolchain.
const _failureDays = 1;

String _toolchainOf(Map<String, String> environment) =>
    '${environment['VisualStudioVersion'] ?? ''} / '
    '${environment['VCToolsVersion'] ?? ''}';

File _failureFile(String cache, _Plugin plugin) =>
    File('$cache\\failed\\${plugin.key}.json');

/// Why [plugin] failed last time, when that still holds; else null.
String? _keptFailure(
  String cache,
  _Plugin plugin,
  Map<String, String> environment,
) {
  if (Platform.environment['RACCOON_RETRY_PLUGINS'] == '1') return null;
  final Object? kept;
  try {
    kept = jsonDecode(_failureFile(cache, plugin).readAsStringSync());
  } on Object {
    return null;
  }
  if (kept is! Map ||
      kept['toolchain'] != _toolchainOf(environment) ||
      kept['at'] is! int ||
      kept['why'] is! String) {
    return null;
  }
  final at = DateTime.fromMillisecondsSinceEpoch(kept['at'] as int);
  if (DateTime.now().difference(at) > const Duration(days: _failureDays)) {
    return null;
  }
  final when = at.toIso8601String().substring(0, 16).replaceFirst('T', ' ');
  return '${kept['why']} (kept from $when; '
      'RACCOON_RETRY_PLUGINS=1 builds it again)';
}

bool _machineStopped(File log) {
  final text = log.readAsStringSync(encoding: latin1);
  return text.contains('There is not enough space on the disk') ||
      text.contains('No space left on device');
}

/// Keeps [plugin]'s failure, [why], with a copy of [log] beside it, and
/// returns [why] naming that copy: the install's own is written over by
/// the next.
String _keepFailure(
  String cache,
  _Plugin plugin,
  Map<String, String> environment,
  String why,
  File log,
) {
  // Not one the machine stopped: a full disk holds no plugin back.
  if (log.existsSync() && _machineStopped(log)) return why;
  final record = _failureFile(cache, plugin);
  record.parent.createSync(recursive: true);
  var kept = why;
  if (log.existsSync()) {
    final copy = record.path.replaceFirst(RegExp(r'\.json$'), '.log');
    log.copySync(copy);
    kept = why.replaceFirst(log.path, copy);
  }
  final staging = File('${record.path}.partial-$pid');
  staging.writeAsStringSync(
    jsonEncode({
      'why': kept,
      'at': DateTime.now().millisecondsSinceEpoch,
      'toolchain': _toolchainOf(environment),
    }),
  );
  // Windows renames over nothing.
  if (record.existsSync()) record.deleteSync();
  staging.renameSync(record.path);
  return kept;
}

final class _Plugin {
  const _Plugin({
    required this.name,
    required this.root,
    required this.symbol,
    required this.key,
  });

  final String name;
  final String root;

  /// `<PluginClass>RegisterWithRegistrar`, or null for an FFI plugin.
  final String? symbol;

  /// Its directory in the cache: plugin version and runner version.
  final String key;
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

/// Renames [staging] into place as [cached]; an install that finished the
/// same entry first keeps its own. Never deletes an entry with anything in
/// it: another install may have just renamed it there, or be copying from
/// it.
void _settle(Directory staging, Directory cached) {
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      staging.renameSync(cached.path);
      return;
    } on FileSystemException {
      // Windows renames over nothing: an empty leftover goes, once.
      if (attempt > 0 || _dllsIn(cached).isNotEmpty) break;
      try {
        cached.deleteSync();
      } on FileSystemException {
        break;
      }
    }
  }
  try {
    staging.deleteSync(recursive: true);
  } on FileSystemException {
    // A file still held open; the next install's staging has its own name.
  }
}

/// A hosted package is its directory name, name-version. A git one is its
/// place in pub's cache, which names the commit. A path package is the shape
/// of its native side, so an edit rebuilds it: every file but its Dart code,
/// tests, examples, build output and hidden folders, so the shared sources
/// an FFI plugin builds (src/) count too, as on the other hosts (#121).
String _versionKey(String name, String root, List<String> pubCaches) {
  // Junctions, subst drives and short names resolved, as pub's paths are
  // compared with the package's.
  String real(String path) {
    try {
      return Directory(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return path;
    }
  }

  String folded(String path) => path
      .replaceAll('/', '\\')
      .toLowerCase()
      .replaceFirst(RegExp(r'\\+$'), '');
  final resolved = real(root);
  final place = folded(resolved);
  final cache = pubCaches
      .map((path) => folded(real(path)))
      .where((cache) => place.startsWith('$cache\\'))
      .firstOrNull;
  if (cache != null && place.startsWith('$cache\\hosted\\')) {
    return resolved.split(RegExp(r'[\\/]')).lastWhere((s) => s.isNotEmpty);
  }
  final shape = StringBuffer();
  if (cache != null) {
    shape.write(place.substring(cache.length));
  } else {
    // A junctioned folder is walked too (shared sources, say), once.
    final seen = <String>{};
    void walk(Directory directory, bool top) {
      if (!seen.add(folded(real(directory.path)))) return;
      final List<FileSystemEntity> found;
      try {
        found = directory.listSync()..sort((a, b) => a.path.compareTo(b.path));
      } on FileSystemException {
        return;
      }
      for (final entry in found) {
        final base = _basename(entry.path);
        if (entry is Directory) {
          if (base.startsWith('.') ||
              (top &&
                  const {'lib', 'test', 'example', 'build'}.contains(base)) ||
              File('${entry.path}\\pubspec.yaml').existsSync()) {
            continue;
          }
          walk(entry, false);
        } else {
          final stat = entry.statSync();
          shape.writeln(
            '${entry.path.substring(root.length)} ${stat.size} '
            '${stat.modified.millisecondsSinceEpoch ~/ 1000}',
          );
        }
      }
    }

    walk(Directory(root), true);
  }
  // FNV-1a, 64 bits: dart: has no hash of its own to offer here.
  var hash = 0xcbf29ce484222325;
  for (final unit in utf8.encode(shape.toString())) {
    hash = ((hash ^ unit) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  final digest = hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  final kind = cache == null ? 'path' : 'git';
  return '$name-$kind-$digest';
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
  final ProcessResult found;
  try {
    found = await Process.run(vswhere, const [
      '-latest',
      '-products',
      '*',
      '-requires',
      'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
      '-property',
      'installationPath',
    ]);
  } on ProcessException {
    throw const _NoToolchain('vswhere failed');
  }
  final install = '${found.stdout}'.trim();
  if (install.isEmpty) {
    throw const _NoToolchain('no Visual Studio with the C++ tools');
  }
  final vcvars = '$install\\VC\\Auxiliary\\Build\\vcvars64.bat';
  final ProcessResult set;
  try {
    set = await Process.run('cmd', ['/c', 'call', vcvars, '>nul', '&&', 'set']);
  } on ProcessException {
    throw const _NoToolchain('vcvars64.bat failed');
  }
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
  // Visual Studio without its CMake component, and none on the PATH: a
  // toolchain missing, not a plugin failing.
  if (_cmakeIn(environment) == null) {
    throw const _NoToolchain('no CMake in Visual Studio or on the PATH');
  }
  return environment;
}

/// cmake.exe on [environment]'s PATH. Windows looks a program up on this
/// process's PATH, not the one it is given, so it is named by its path.
String? _cmakeIn(Map<String, String> environment) {
  for (final directory in (environment['PATH'] ?? '').split(';')) {
    if (directory.isEmpty) continue;
    final path = '$directory\\cmake.exe';
    if (File(path).existsSync()) return path;
  }
  return null;
}

/// Runs Visual Studio's cmake with [arguments], its output into [log].
Future<bool> _run(
  Map<String, String> environment,
  File log,
  List<String> arguments,
) async {
  final cmake = _cmakeIn(environment) ?? 'cmake';
  // The developer prompt's whole environment, on its own: merged into
  // this process's, names differing only in case (WINDOWSSDKBINPATH from a
  // shell that upper-cases them, WindowsSdkBinPath from vcvars) both reach
  // MSBuild, which then can't start the compiler (#141).
  final result = await Process.run(
    cmake,
    arguments,
    environment: environment,
    includeParentEnvironment: false,
  );
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

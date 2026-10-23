// raccoon-device's way into a pub workspace, in Dart: every host has the
// SDK's dart, Windows has no python3. Run with no package of its own, so
// dart: libraries only.
//
//   dart package_scope.dart <project> <out>
//
// A workspace member (resolution: workspace) has no package config of its
// own; the workspace root's names every member's packages. This finds the
// nearest config above the project, keeps what the app reaches (its
// dependencies and dev dependencies, then theirs, as pub records them in
// package_graph.json beside the config), and writes those to <out> with
// absolute roots, for the plugin and native asset steps to read as the
// app's own. Without a graph it keeps every package. Prints <out>; says why
// on stderr and exits 1 when no config above names the project.

import 'dart:convert';
import 'dart:io';

void main(List<String> arguments) {
  if (arguments.length != 2) {
    stderr.writeln('usage: package_scope.dart <project> <out>');
    exitCode = 2;
    return;
  }
  final [projectPath, out] = arguments;
  final project = Directory(projectPath).absolute.resolveSymbolicLinksSync();

  for (var dir = Directory(project).parent; ; dir = dir.parent) {
    final config = File(
      '${dir.path}${Platform.pathSeparator}.dart_tool'
      '${Platform.pathSeparator}package_config.json',
    );
    if (config.existsSync()) {
      exitCode = _scope(config, project, out);
      return;
    }
    if (dir.parent.path == dir.path) break;
  }
  stderr.writeln(
    'raccoon-device: no .dart_tool/package_config.json for $project; '
    'run flutter pub get',
  );
  exitCode = 1;
}

int _scope(File config, String project, String out) {
  final dartTool = Uri.directory(config.parent.path);
  final decoded = jsonDecode(config.readAsStringSync()) as Map;
  final packages = <String, Map<String, Object?>>{};
  String? app;
  for (final entry in (decoded['packages'] as List? ?? const [])) {
    final package = Map<String, Object?>.from(entry as Map);
    final root = dartTool.resolve('${package['rootUri'] ?? ''}');
    package['rootUri'] = root.toString();
    final name = '${package['name']}';
    packages[name] = package;
    final directory = Directory(root.toFilePath());
    if (directory.existsSync() &&
        directory.resolveSymbolicLinksSync() == project) {
      app = name;
    }
  }
  if (app == null) {
    stderr.writeln(
      'raccoon-device: ${config.path} does not name $project; '
      'run flutter pub get',
    );
    return 1;
  }

  final graph = File(
    '${config.parent.path}${Platform.pathSeparator}package_graph.json',
  );
  var kept = packages.keys.toSet();
  if (graph.existsSync()) {
    final edges = <String, List<String>>{};
    final devEdges = <String, List<String>>{};
    final nodes = (jsonDecode(graph.readAsStringSync()) as Map)['packages'];
    for (final node in (nodes as List? ?? const [])) {
      final name = '${(node as Map)['name']}';
      edges[name] = [for (final d in node['dependencies'] as List? ?? []) '$d'];
      devEdges[name] = [
        for (final d in node['devDependencies'] as List? ?? []) '$d',
      ];
    }
    kept = {};
    final pending = [app, ...?devEdges[app]];
    while (pending.isNotEmpty) {
      final name = pending.removeLast();
      if (!kept.add(name)) continue;
      pending.addAll(edges[name] ?? const []);
    }
  }

  File(out)
    ..createSync(recursive: true)
    ..writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'configVersion': 2,
        'packages': [
          for (final MapEntry(:key, :value) in packages.entries)
            if (kept.contains(key)) value,
        ],
        'generator': 'raccoon-device',
      }),
    );
  stdout.writeln(out);
  return 0;
}

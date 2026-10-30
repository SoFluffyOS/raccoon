// raccoon-device's way into a pub workspace, in Dart: every host has the
// SDK's dart, Windows has no python3. Run with no package of its own, so
// dart: libraries only.
//
//   dart package_scope.dart <project> <out>
//
// A workspace member (resolution: workspace) has no package config of its
// own; the workspace root's names every member's packages. This finds the
// root's config, by the member's .dart_tool/pub/workspace_ref.json or else
// the nearest config above that names it, keeps what the app reaches (its
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

  // Pub names the root in the member: a config left in a folder between,
  // from before the move to a workspace, is not taken for it (#141).
  final sep = Platform.pathSeparator;
  final ref = File('$project$sep.dart_tool${sep}pub${sep}workspace_ref.json');
  if (ref.existsSync()) {
    try {
      final root = (jsonDecode(ref.readAsStringSync()) as Map)['workspaceRoot'];
      final rootDir = Uri.directory(ref.parent.path).resolve('$root/');
      final config = File.fromUri(
        rootDir.resolve('.dart_tool/package_config.json'),
      );
      if (config.existsSync() && _scope(config, project, out)) return;
    } on Object {
      // Not one pub wrote: the search below finds the root.
    }
  }
  final passed = <String>[];
  for (var dir = Directory(project).parent; ; dir = dir.parent) {
    final config = File('${dir.path}$sep.dart_tool${sep}package_config.json');
    if (config.existsSync()) {
      if (_scope(config, project, out)) return;
      passed.add(config.path);
    }
    if (dir.parent.path == dir.path) break;
  }
  stderr.writeln(switch (passed) {
    [] =>
      'raccoon-device: no .dart_tool/package_config.json for $project; '
          'run flutter pub get',
    _ =>
      'raccoon-device: no package config above names $project '
          '(${passed.join(', ')}); run flutter pub get',
  });
  exitCode = 1;
}

/// Writes [out] from [config]; false when [config] does not name [project],
/// as for one that can't be read: the search goes on past it.
bool _scope(File config, String project, String out) {
  final dartTool = Uri.directory(config.parent.path);
  final listed = switch (_read(config)) {
    {'packages': final List<Object?> packages} => packages,
    _ => const <Object?>[],
  };
  final packages = <String, Map<String, Object?>>{};
  String? app;
  for (final entry in listed) {
    if (entry is! Map) continue;
    final package = Map<String, Object?>.from(entry);
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
  if (app == null) return false;

  final graph = File(
    '${config.parent.path}${Platform.pathSeparator}package_graph.json',
  );
  var kept = packages.keys.toSet();
  // One that can't be read is as none: every package is kept.
  final nodes = switch (graph.existsSync() ? _read(graph) : null) {
    {'packages': final List<Object?> listed} => listed,
    _ => null,
  };
  if (nodes != null) {
    final edges = <String, List<String>>{};
    final devEdges = <String, List<String>>{};
    for (final node in nodes) {
      if (node is! Map) continue;
      final name = '${node['name']}';
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
  return true;
}

/// [file]'s JSON, or null when it isn't JSON or can't be read.
Object? _read(File file) {
  try {
    return jsonDecode(file.readAsStringSync());
  } on Exception {
    return null;
  }
}

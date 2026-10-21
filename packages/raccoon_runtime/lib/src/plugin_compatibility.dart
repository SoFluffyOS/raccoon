import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// How a project's plugin fares in the runtime.
enum PluginSupport {
  /// Its Linux implementation is Dart, so it works unchanged.
  works,

  /// Its Linux implementation is native and Raccoon provides one.
  servedByRaccoon,

  /// Its Linux implementation is native and nothing serves it yet; calls
  /// throw `MissingPluginException`, as on an unsupported desktop today.
  unavailable,

  /// The plugin has no Linux implementation at all (mobile or web only).
  notForThisPlatform,
}

final class PluginStatus {
  const PluginStatus({required this.name, required this.support});

  final String name;
  final PluginSupport support;

  @override
  String toString() => '$name: ${support.name}';
}

/// Reads the Flutter tool's `.flutter-plugins-dependencies` and says, per
/// plugin, what the runtime can do with it (see design note 004).
final class PluginCompatibility {
  const PluginCompatibility({this.servedByRaccoon = const {}});

  /// Names of native Linux plugin packages Raccoon implements in Dart.
  final Set<String> servedByRaccoon;

  static const String fileName = '.flutter-plugins-dependencies';

  /// The report for the project at [projectDirectory], or an empty list when
  /// the tool has not written the file yet.
  List<PluginStatus> forProject(String projectDirectory) {
    final file = File(p.join(projectDirectory, fileName));
    if (!file.existsSync()) return const [];
    return parse(file.readAsStringSync());
  }

  List<PluginStatus> parse(String json, {String platform = 'linux'}) {
    final decoded = jsonDecode(json);
    if (decoded is! Map || decoded['plugins'] is! Map) return const [];
    final platforms = decoded['plugins'] as Map;
    final onPlatform = <String, bool>{};
    for (final entry in platforms[platform] as List? ?? const []) {
      if (entry case {'name': final String name}) {
        onPlatform[name] = entry['native_build'] == true;
      }
    }
    final everywhere = <String>{};
    for (final list in platforms.values) {
      for (final entry in list as List? ?? const []) {
        if (entry case {'name': final String name}) everywhere.add(name);
      }
    }
    final report = <PluginStatus>[];
    for (final name in everywhere.toList()..sort()) {
      final native = onPlatform[name];
      final support = switch (native) {
        null => PluginSupport.notForThisPlatform,
        false => PluginSupport.works,
        true when servedByRaccoon.contains(name) =>
          PluginSupport.servedByRaccoon,
        true => PluginSupport.unavailable,
      };
      report.add(PluginStatus(name: name, support: support));
    }
    return report;
  }
}

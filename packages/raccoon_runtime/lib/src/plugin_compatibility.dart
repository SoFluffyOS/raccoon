import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// How a project's plugin fares in the runtime.
enum PluginSupport {
  /// Its implementation for this host is Dart, so it works unchanged.
  works,

  /// Its implementation for this host is native and Raccoon provides one.
  servedByRaccoon,

  /// Its implementation for this host is native and nothing serves it yet;
  /// calls throw `MissingPluginException`, as on an unsupported desktop today.
  unavailable,

  /// The plugin has no implementation for this host at all (mobile or web
  /// only).
  notForThisPlatform,
}

/// One of a project's plugins and how it fares in the runtime.
final class PluginStatus {
  const PluginStatus({required this.name, required this.support});

  /// The plugin's package name.
  final String name;

  /// What the runtime can do with it on this host.
  final PluginSupport support;

  @override
  String toString() => '$name: ${support.name}';
}

/// Reads the Flutter tool's `.flutter-plugins-dependencies` and says, per
/// plugin, what the runtime can do with it.
final class PluginCompatibility {
  PluginCompatibility({
    this.servedByRaccoon = defaultServedByRaccoon,
    String? platform,
  }) : platform = platform ?? hostPlatform;

  /// Native plugin packages the IDE serves over platform channels today (see
  /// `IdePlatformChannels` and `IdeUrlLauncherChannels` in raccoon_view).
  static const Set<String> defaultServedByRaccoon = {
    'url_launcher_linux',
    'url_launcher_macos',
    'url_launcher_windows',
  };

  /// The tool's name for the host this process runs on.
  static final String hostPlatform = platformFor(Platform.operatingSystem);

  /// The key the tool's file lists a desktop's plugins under.
  static String platformFor(String operatingSystem) =>
      switch (operatingSystem) {
        'linux' || 'macos' || 'windows' => operatingSystem,
        _ => throw UnsupportedError('no desktop plugins on $operatingSystem'),
      };

  /// Names of native plugin packages Raccoon implements in Dart.
  final Set<String> servedByRaccoon;

  /// The platform whose plugin list the report reads.
  final String platform;

  /// The file the Flutter tool writes at a project's root, listing its
  /// plugins per platform.
  static const String fileName = '.flutter-plugins-dependencies';

  /// The report for the project at [projectDirectory], or an empty list when
  /// the tool has not written the file yet, or is writing it: it truncates
  /// the file first, so a read can find it empty or cut short (#134).
  List<PluginStatus> forProject(String projectDirectory) {
    final file = File(p.join(projectDirectory, fileName));
    if (!file.existsSync()) return const [];
    try {
      return parse(file.readAsStringSync());
    } on FormatException {
      return const [];
    } on FileSystemException {
      // Cut inside a character, as a read during the rewrite can find it.
      return const [];
    }
  }

  /// The report in [json]; empty for a shape that isn't the tool's.
  List<PluginStatus> parse(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! Map || decoded['plugins'] is! Map) return const [];
    final platforms = decoded['plugins'] as Map;
    List<Object?> entriesOf(Object? list) => switch (list) {
      final List<Object?> entries => entries,
      _ => const [],
    };
    final onPlatform = <String, bool>{};
    for (final entry in entriesOf(platforms[platform])) {
      if (entry case final Map map && {'name': final String name}) {
        onPlatform[name] = map['native_build'] == true;
      }
    }
    final everywhere = <String>{};
    for (final list in platforms.values) {
      for (final entry in entriesOf(list)) {
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

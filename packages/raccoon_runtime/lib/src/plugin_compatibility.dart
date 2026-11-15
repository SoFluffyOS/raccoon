import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// How a project's plugin fares in the runtime.
enum PluginSupport {
  /// Its implementation for this host is Dart, so it works unchanged.
  works,

  /// Its implementation for this host is native: the device helper builds
  /// it for the host and the runner loads it, as the app's own desktop build
  /// would. One that does not build is named when the app runs, and its
  /// calls fail as on a desktop without it.
  native,

  /// Its implementation for this host is native and the runner answers its
  /// channels itself instead: the window plugins, whose window is the pane.
  servedByRaccoon,

  /// The plugin has no implementation for this host at all (mobile or web
  /// only); its calls fail as they would in the app's own desktop build.
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
  PluginCompatibility({Set<String>? servedByRaccoon, String? platform})
    : platform = platform ?? hostPlatform,
      servedByRaccoon = servedByRaccoon ?? servedOn(platform ?? hostPlatform);

  /// Native plugin packages the runner answers itself on every host, as the
  /// device helper lists them: their window is the pane.
  static const Set<String> defaultServedByRaccoon = {
    'desktop_window',
    'window_manager',
    'window_size',
    'screen_retriever',
    'screen_retriever_linux',
    'screen_retriever_macos',
    'screen_retriever_windows',
  };

  /// What the runner answers itself on [platform]: on a Mac also
  /// `shared_preferences_foundation`, which the app's Dart VM picks there.
  static Set<String> servedOn(String platform) => {
    ...defaultServedByRaccoon,
    if (platform == 'macos') 'shared_preferences_foundation',
  };

  /// The tool's name for the host this process runs on.
  static final String hostPlatform = platformFor(Platform.operatingSystem);

  /// The key the tool's file lists a desktop's plugins under.
  static String platformFor(String operatingSystem) =>
      switch (operatingSystem) {
        'linux' || 'macos' || 'windows' => operatingSystem,
        _ => throw UnsupportedError('no desktop plugins on $operatingSystem'),
      };

  /// Names of native plugin packages the runner answers itself.
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
        true => PluginSupport.native,
      };
      report.add(PluginStatus(name: name, support: support));
    }
    return report;
  }
}

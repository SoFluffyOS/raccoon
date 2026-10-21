import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The "raccoon" entry for the Flutter tool's custom devices, so a stock
/// `flutter run -d raccoon` builds the bundle, installs it with the device
/// helper and starts the runner.
final class CustomDeviceConfig {
  const CustomDeviceConfig({
    required this.deviceHelper,
    this.id = 'raccoon',
    this.label = 'Raccoon',
    this.sdkNameAndVersion = 'Raccoon runtime',
    this.platform = 'linux-x64',
  });

  /// Path to the `raccoon-device` helper (ping, install, uninstall, run).
  final String deviceHelper;
  final String id;
  final String label;
  final String sdkNameAndVersion;
  final String platform;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'sdkNameAndVersion': sdkNameAndVersion,
    'platform': platform,
    'enabled': true,
    'ping': [deviceHelper, 'ping'],
    'pingSuccessRegex': null,
    'postBuild': null,
    'install': [deviceHelper, 'install', r'${localPath}', r'${appName}'],
    'uninstall': [deviceHelper, 'uninstall', r'${appName}'],
    'runDebug': [deviceHelper, 'run', r'${appName}', r'${engineOptions}'],
    'forwardPort': null,
    'forwardPortSuccessRegex': null,
    'screenshot': null,
    'readLogs': null,
  };
}

/// Reads and writes the tool's `custom_devices.json`, keeping other entries.
final class CustomDevicesFile {
  const CustomDevicesFile(this.path);

  /// The tool's location on this host: `$XDG_CONFIG_HOME/flutter` or
  /// `~/.config/flutter`.
  factory CustomDevicesFile.forHost(Map<String, String> environment) {
    final configHome = switch (environment['XDG_CONFIG_HOME']) {
      final dir? when dir.isNotEmpty => dir,
      _ => p.join(environment['HOME'] ?? '', '.config'),
    };
    return CustomDevicesFile(
      p.join(configHome, 'flutter', 'custom_devices.json'),
    );
  }

  static const _key = 'custom-devices';

  final String path;

  /// Adds or replaces the entry whose id matches [config]'s.
  void upsert(CustomDeviceConfig config) {
    final file = File(path);
    final devices = <Object?>[];
    if (file.existsSync()) {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded case {_key: final List<Object?> existing}) {
        devices.addAll(
          existing.where((d) => d is! Map || d['id'] != config.id),
        );
      }
    }
    devices.add(config.toJson());
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({_key: devices})}\n',
    );
  }

  /// Ids of the configured devices.
  List<String> ids() {
    final file = File(path);
    if (!file.existsSync()) return const [];
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded case {_key: final List<Object?> devices}) {
      return [
        for (final device in devices)
          if (device case {'id': final String id}) id,
      ];
    }
    return const [];
  }
}

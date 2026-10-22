import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:raccoon_runtime/src/raccoon_device.dart';

/// The "raccoon" entry for the Flutter tool's custom devices, so a stock
/// `flutter run -d raccoon` builds the bundle, installs it with the device
/// helper and starts the runner.
final class CustomDeviceConfig {
  CustomDeviceConfig({
    required this.deviceHelper,
    this.instance = '1',
    String? id,
    String? label,
    this.sdkNameAndVersion = 'Raccoon runtime',
    String? platform,
    String? size,
  }) : id = id ?? (instance == '1' ? 'raccoon' : 'raccoon-$instance'),
       size = size ?? RaccoonDevice.forKey(instance)?.sizeArgument,
       label =
           label ??
           RaccoonDevice.forKey(instance)?.label ??
           (instance == '1' ? 'Raccoon' : 'Raccoon $instance'),
       platform = platform ?? hostPlatform;

  /// The entry for a device, built in or the user's own: its id, label
  /// and, for the sized ones, the size the runner starts at.
  CustomDeviceConfig.forDevice(
    RaccoonDevice device, {
    required String deviceHelper,
    String? platform,
  }) : this(
         deviceHelper: deviceHelper,
         instance: device.key,
         id: device.id,
         label: device.label,
         platform: platform,
         size: device.sizeArgument,
       );

  /// The tool's platform name for the host this process runs on.
  static final String hostPlatform = platformFor(Abi.current());

  /// The tool accepts only `linux-x64` and `linux-arm64` as a custom device's
  /// platform, whatever the host. That is fine: a debug bundle is built from
  /// the host's own snapshots regardless, and the runner loads the host's
  /// engine. Naming the host's architecture keeps the tool's artifact paths
  /// honest at least.
  static String platformFor(Abi abi) => switch (abi) {
    Abi.linuxArm64 || Abi.macosArm64 || Abi.windowsArm64 => 'linux-arm64',
    Abi.linuxX64 || Abi.macosX64 || Abi.windowsX64 => 'linux-x64',
    _ => throw UnsupportedError('no custom device platform for $abi'),
  };

  /// Path to the `raccoon-device` helper (ping, install, uninstall, run).
  final String deviceHelper;

  /// Which run of a project this device hosts. 1 is `raccoon`; `raccoon-N`
  /// keeps a second run of the same project apart from the first, with its
  /// own socket, app store and data directory (the helper's `--instance`).
  /// The instance key the helper keeps this device's runs under: `1` for
  /// the first device, `2`, `phone`, `tablet`, `desktop`, or a name.
  final String instance;
  final String id;
  final String label;
  final String sdkNameAndVersion;

  /// What the tool is told, see [platformFor].
  final String platform;

  /// The size the runner starts this device at, `390x844@3`; null for the
  /// host's own size.
  final String? size;

  List<String> get _instanceArgs =>
      instance == '1' ? const [] : ['--instance', instance];

  /// The size the device starts at, for `run`.
  List<String> get _sizeArgs => switch (size) {
    final size? => ['--size', size],
    null => const [],
  };

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'sdkNameAndVersion': sdkNameAndVersion,
    'platform': platform,
    'enabled': true,
    'ping': [deviceHelper, 'ping'],
    'pingSuccessRegex': null,
    'postBuild': null,
    'install': [
      deviceHelper,
      'install',
      ..._instanceArgs,
      r'${localPath}',
      r'${appName}',
    ],
    'uninstall': [deviceHelper, 'uninstall', ..._instanceArgs, r'${appName}'],
    'runDebug': [
      deviceHelper,
      'run',
      ..._instanceArgs,
      ..._sizeArgs,
      r'${appName}',
      r'${engineOptions}',
    ],
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

  /// Removes the entry with [id]; tells whether there was one.
  bool remove(String id) {
    final file = File(path);
    if (!file.existsSync()) return false;
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded case {_key: final List<Object?> existing}) {
      final kept = existing.where((d) => d is! Map || d['id'] != id).toList();
      if (kept.length == existing.length) return false;
      file.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert({_key: kept})}\n',
      );
      return true;
    }
    return false;
  }

  /// The device helper the entry with [id] runs, read off its ping
  /// command; null without such an entry. The `raccoon` entry's helper is
  /// what every added device points at.
  String? helperOf(String id) => switch (_entry(id)) {
    {'ping': final List ping} when ping.isNotEmpty => ping.first as String?,
    _ => null,
  };

  /// The label of the entry with [id]; null without one.
  String? labelOf(String id) => switch (_entry(id)) {
    {'label': final String label} => label,
    _ => null,
  };

  /// The size the entry with [id] runs at, read off its run command's
  /// `--size`; null without one.
  String? sizeOf(String id) {
    if (_entry(id) case {'runDebug': final List run}) {
      final at = run.indexOf('--size');
      if (at >= 0 && at + 1 < run.length) return run[at + 1] as String?;
    }
    return null;
  }

  Map? _entry(String id) {
    final file = File(path);
    if (!file.existsSync()) return null;
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded case {_key: final List<Object?> devices}) {
      for (final device in devices) {
        if (device case {'id': final String deviceId} when deviceId == id) {
          return device as Map;
        }
      }
    }
    return null;
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

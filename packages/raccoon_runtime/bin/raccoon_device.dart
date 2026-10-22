// Developer commands for the Raccoon runtime.
//
//   dart run raccoon_runtime:raccoon_device setup --helper <path/to/raccoon-device>
//   dart run raccoon_runtime:raccoon_device add <phone|tablet|desktop|name> [--size WxH@R] [--label text]
//   dart run raccoon_runtime:raccoon_device remove <name>
//   dart run raccoon_runtime:raccoon_device list
//   dart run raccoon_runtime:raccoon_device doctor [project directory]

import 'dart:io';

import 'package:raccoon_runtime/raccoon_runtime.dart';

void main(List<String> arguments) {
  final file = CustomDevicesFile.forHost(Platform.environment);
  switch (arguments) {
    case ['setup', '--helper', final helper]:
      // One device to start with; add and remove the rest as wanted.
      file.upsert(
        CustomDeviceConfig.forDevice(RaccoonDevice.host, deviceHelper: helper),
      );
      stdout.writeln('wrote ${file.path}: ${file.ids().join(', ')}');
    case ['add', final name, ...final options]:
      exitCode = _add(file, name, options);
    case ['remove', final name]:
      final id = name.startsWith('raccoon') ? name : 'raccoon-$name';
      if (file.remove(id)) {
        stdout.writeln('removed $id from ${file.path}');
      } else {
        stderr.writeln('no $id in ${file.path}');
        exitCode = 1;
      }
    case ['list']:
      final ids = file.ids().where((id) => id.startsWith('raccoon'));
      stdout.writeln(ids.isEmpty ? 'no Raccoon devices' : ids.join('\n'));
    case ['doctor', ...final rest]:
      _doctor(rest.firstOrNull ?? Directory.current.path);
    default:
      stderr.writeln(
        'usage: raccoon_device setup --helper <path/to/raccoon-device>\n'
        '       raccoon_device add <phone|tablet|desktop|name> '
        '[--size WxH@R] [--label text] [--helper path]\n'
        '       raccoon_device remove <name>\n'
        '       raccoon_device list\n'
        '       raccoon_device doctor [project directory]',
      );
      exitCode = 2;
  }
}

/// Adds a device: a preset by name, or a name of the user's own with a
/// size. The helper is the `raccoon` entry's unless given.
int _add(CustomDevicesFile file, String name, List<String> options) {
  String? size;
  String? label;
  String? helper;
  for (var i = 0; i < options.length; i++) {
    switch (options[i]) {
      case '--size' when i + 1 < options.length:
        size = options[++i];
      case '--label' when i + 1 < options.length:
        label = options[++i];
      case '--helper' when i + 1 < options.length:
        helper = options[++i];
      default:
        stderr.writeln('unknown option ${options[i]}');
        return 2;
    }
  }
  final key = name.startsWith('raccoon-') ? name.substring(8) : name;
  final RaccoonDevice device;
  try {
    final preset = RaccoonDevice.forKey(key);
    device = switch (preset) {
      final preset? when size == null && label == null => preset,
      _ => RaccoonDevice.custom(
        key,
        size: size ?? preset?.sizeArgument,
        label: label ?? preset?.label,
      ),
    };
  } on ArgumentError catch (error) {
    stderr.writeln('${error.message}: ${error.invalidValue}');
    return 2;
  }
  helper ??= file.helperOf('raccoon');
  if (helper == null) {
    stderr.writeln(
      'no raccoon device in ${file.path}: run setup first, or pass --helper',
    );
    return 1;
  }
  file.upsert(CustomDeviceConfig.forDevice(device, deviceHelper: helper));
  stdout.writeln(
    'added ${device.id} (${device.label}'
    '${device.sizeArgument == null ? '' : ', ${device.sizeArgument}'}) '
    'to ${file.path}',
  );
  return 0;
}

void _doctor(String project) {
  final sdk = RuntimeStore.sdkRootOnPath();
  if (sdk == null) {
    stdout.writeln('flutter: not on PATH');
    return;
  }
  final revision = RuntimeStore.revisionOfSdk(sdk);
  final store = RuntimeStore.forHost(Platform.environment);
  final runtime = revision == null ? null : store.installed(revision);
  stdout
    ..writeln('flutter sdk: $sdk')
    ..writeln('engine revision: ${revision ?? 'unknown'}')
    ..writeln('runtime: ${runtime?.directory ?? 'not installed'}')
    ..writeln('icu data: ${File(RuntimeStore.icuDataOfSdk(sdk)).existsSync()}')
    ..writeln(
      'custom devices: ${CustomDevicesFile.forHost(Platform.environment).ids().join(', ')}',
    );
  final report = PluginCompatibility().forProject(project);
  stdout.writeln(
    'plugins in $project: ${report.isEmpty ? 'none recorded' : ''}',
  );
  for (final status in report) {
    stdout.writeln('  $status');
  }
}

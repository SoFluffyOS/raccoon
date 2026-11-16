// Developer commands for the Raccoon runtime.
//
//   dart run raccoon_runtime:raccoon_device setup --helper <path/to/raccoon-device>
//   dart run raccoon_runtime:raccoon_device add <phone|tablet|desktop|name> [--size WxH@R] [--label text]
//   dart run raccoon_runtime:raccoon_device remove <name>
//   dart run raccoon_runtime:raccoon_device list
//   dart run raccoon_runtime:raccoon_device doctor [project directory]
//   dart run raccoon_runtime:raccoon_device fetch --into <directory> [--version V]

import 'dart:async';
import 'dart:io';

import 'package:raccoon_runtime/raccoon_runtime.dart';

Future<void> main(List<String> arguments) async {
  final file = CustomDevicesFile.forHost(Platform.environment);
  switch (arguments) {
    case ['setup', '--helper', final given]:
      final helper = _helperPath(given);
      if (helper == null) {
        exitCode = 1;
        return;
      }
      // One device to start with; add and remove the rest as wanted.
      file.upsert(
        CustomDeviceConfig.forDevice(RaccoonDevice.host, deviceHelper: helper),
      );
      stdout.writeln('wrote ${file.path}: ${file.ids().join(', ')}');
    case ['add', final name, ...final options]:
      exitCode = _add(file, name, options);
    case ['remove', final name]:
      // As add names it: `raccoonish` is raccoon-raccoonish.
      final id =
          name == 'raccoon' || name.startsWith('raccoon-')
              ? name
              : 'raccoon-$name';
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
    case ['fetch', ...final options]:
      exitCode = await _fetch(options);
    default:
      stderr.writeln(
        'usage: raccoon_device setup --helper <path/to/raccoon-device>\n'
        '       raccoon_device add <phone|tablet|desktop|name> '
        '[--size WxH@R] [--label text] [--helper path]\n'
        '       raccoon_device remove <name>\n'
        '       raccoon_device list\n'
        '       raccoon_device doctor [project directory]\n'
        '       raccoon_device fetch --into <directory> [--version V]',
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
        helper = _helperPath(options[++i]);
        if (helper == null) return 1;
      // One of them last, with nothing after it (#339).
      case '--size' || '--label' || '--helper':
        stderr.writeln('${options[i]} needs a value');
        return 2;
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

/// [given] as an absolute path: Flutter runs the helper from the project's
/// directory, not this one. Null, said on stderr, when it is not a file.
String? _helperPath(String given) {
  final helper = File(given).absolute.path;
  if (!File(helper).existsSync()) {
    stderr.writeln('no helper at $helper');
    return null;
  }
  return helper;
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

/// Downloads the prebuilt runner from the `runner-v*` releases into the
/// directory after `--into`: the newest release compatible with the
/// runtime's own version, or with `--version`. Prints the device helper's
/// path, for setup.
Future<int> _fetch(List<String> options) async {
  String? into;
  String? asked;
  for (var i = 0; i < options.length; i++) {
    switch (options[i]) {
      case '--into' when i + 1 < options.length:
        into = options[++i];
      case '--version' when i + 1 < options.length:
        asked = options[++i];
      case '--into' || '--version':
        stderr.writeln('${options[i]} needs a value');
        return 2;
      default:
        stderr.writeln('unknown option ${options[i]}');
        return 2;
    }
  }
  if (into == null) {
    stderr.writeln('fetch needs --into <directory>');
    return 2;
  }
  final version = RunnerVersion.parse(asked ?? RunnerVersion.current);
  if (version == null) {
    stderr.writeln('not a version: $asked');
    return 2;
  }
  final runner = PrebuiltRunner(
    Directory(into).absolute.path,
    isWindows: Platform.isWindows,
  );
  final downloader = RunnerDownloader();
  try {
    final release = await downloader.find(version);
    if (release == null) {
      stderr.writeln(
        'no runner release for ${downloader.platform} compatible with $version',
      );
      return 1;
    }
    if (runner.version case final have? when have == release.version) {
      stdout.writeln(runner.deviceHelper);
      return 0;
    }
    final clock = Stopwatch()..start();
    await downloader.install(release, runner);
    stderr.writeln(
      'runner ${release.version} in ${runner.directory} '
      '(${clock.elapsedMilliseconds} ms)',
    );
    stdout.writeln(runner.deviceHelper);
    return 0;
  } on DownloadFailed catch (error) {
    stderr.writeln('$error');
    return 1;
  }
}

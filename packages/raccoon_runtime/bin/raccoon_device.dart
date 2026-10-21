// Developer commands for the Raccoon runtime.
//
//   dart run raccoon_runtime:raccoon_device setup --helper <path/to/raccoon-device>
//   dart run raccoon_runtime:raccoon_device doctor [project directory]

import 'dart:io';

import 'package:raccoon_runtime/raccoon_runtime.dart';

void main(List<String> arguments) {
  switch (arguments) {
    case ['setup', '--helper', final helper]:
      final file = CustomDevicesFile.forHost(Platform.environment);
      // raccoon, and raccoon-2 for a second run of the same project.
      for (final instance in const [1, 2]) {
        file.upsert(
          CustomDeviceConfig(deviceHelper: helper, instance: instance),
        );
      }
      stdout.writeln('wrote ${file.path}: ${file.ids().join(', ')}');
    case ['doctor', ...final rest]:
      _doctor(rest.firstOrNull ?? Directory.current.path);
    default:
      stderr.writeln(
        'usage: raccoon_device setup --helper <path/to/raccoon-device>\n'
        '       raccoon_device doctor [project directory]',
      );
      exitCode = 2;
  }
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

// Registers the "raccoon" custom device with the Flutter tool.
//
//   dart run raccoon_runtime:raccoon_device setup --helper <path/to/raccoon-device>

import 'dart:io';

import 'package:raccoon_runtime/raccoon_runtime.dart';

void main(List<String> arguments) {
  if (arguments.length < 3 ||
      arguments[0] != 'setup' ||
      arguments[1] != '--helper') {
    stderr.writeln(
      'usage: raccoon_device setup --helper <path/to/raccoon-device>',
    );
    exitCode = 2;
    return;
  }
  final file = CustomDevicesFile.forHost(Platform.environment);
  file.upsert(CustomDeviceConfig(deviceHelper: arguments[2]));
  stdout.writeln('wrote ${file.path}: ${file.ids().join(', ')}');
}

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('raccoon_cfg'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('resolves the tool config path from XDG_CONFIG_HOME, then HOME', () {
    expect(
      CustomDevicesFile.forHost({'XDG_CONFIG_HOME': '/xdg', 'HOME': '/h'}).path,
      '/xdg/flutter/custom_devices.json',
    );
    expect(
      CustomDevicesFile.forHost({'HOME': '/h'}).path,
      '/h/.config/flutter/custom_devices.json',
    );
  });

  test('tells the tool a linux platform of the host architecture', () {
    expect(CustomDeviceConfig.platformFor(Abi.linuxX64), 'linux-x64');
    expect(CustomDeviceConfig.platformFor(Abi.macosArm64), 'linux-arm64');
    expect(CustomDeviceConfig.platformFor(Abi.macosX64), 'linux-x64');
    expect(CustomDeviceConfig.platformFor(Abi.windowsArm64), 'linux-arm64');
    expect(
      CustomDeviceConfig(deviceHelper: '/a/raccoon-device').platform,
      CustomDeviceConfig.hostPlatform,
    );
  });

  test('upsert creates the file and replaces its own entry', () {
    final file = CustomDevicesFile(p.join(temp.path, 'custom_devices.json'));

    file.upsert(CustomDeviceConfig(deviceHelper: '/a/raccoon-device'));
    file.upsert(
      CustomDeviceConfig(
        deviceHelper: '/b/raccoon-device',
        platform: 'linux-x64',
      ),
    );

    final decoded = jsonDecode(File(file.path).readAsStringSync());
    final devices = (decoded as Map)['custom-devices'] as List;
    expect(devices, hasLength(1));
    final entry = devices.single as Map;
    expect(entry['runDebug'], [
      '/b/raccoon-device',
      'run',
      r'${appName}',
      r'${engineOptions}',
    ]);
    expect(entry['install'], contains(r'${localPath}'));
    expect(entry['platform'], 'linux-x64');
  });

  test('upsert keeps other devices', () {
    final file = CustomDevicesFile(p.join(temp.path, 'custom_devices.json'));
    File(file.path).writeAsStringSync(
      jsonEncode({
        'custom-devices': [
          {'id': 'pi', 'label': 'Pi'},
        ],
      }),
    );

    file.upsert(CustomDeviceConfig(deviceHelper: '/x/raccoon-device'));

    expect(file.ids(), ['pi', 'raccoon']);
  });
}

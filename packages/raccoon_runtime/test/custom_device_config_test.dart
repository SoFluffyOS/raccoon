import 'dart:convert';
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

  test('upsert creates the file and replaces its own entry', () {
    final file = CustomDevicesFile(p.join(temp.path, 'custom_devices.json'));

    file.upsert(const CustomDeviceConfig(deviceHelper: '/a/raccoon-device'));
    file.upsert(const CustomDeviceConfig(deviceHelper: '/b/raccoon-device'));

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

    file.upsert(const CustomDeviceConfig(deviceHelper: '/x/raccoon-device'));

    expect(file.ids(), ['pi', 'raccoon']);
  });
}

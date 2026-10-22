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

  test('a second instance is raccoon-2 with --instance in its commands', () {
    final config = CustomDeviceConfig(deviceHelper: '/h', instance: '2');
    expect(config.id, 'raccoon-2');
    expect(config.label, 'Raccoon 2');
    final json = config.toJson();
    expect(json['install'], [
      '/h',
      'install',
      '--instance',
      '2',
      r'${localPath}',
      r'${appName}',
    ]);
    expect(json['uninstall'], [
      '/h',
      'uninstall',
      '--instance',
      '2',
      r'${appName}',
    ]);
    expect(json['runDebug'], [
      '/h',
      'run',
      '--instance',
      '2',
      r'${appName}',
      r'${engineOptions}',
    ]);
    final first = CustomDeviceConfig(deviceHelper: '/h').toJson();
    expect(first['id'], 'raccoon');
    expect(first['runDebug'], [
      '/h',
      'run',
      r'${appName}',
      r'${engineOptions}',
    ]);
  });

  test('app names carry their instance', () {
    expect(RunnerDiscovery.projectOf('wonders'), 'wonders');
    expect(RunnerDiscovery.instanceOf('wonders'), '1');
    expect(RunnerDiscovery.projectOf('wonders@2'), 'wonders');
    expect(RunnerDiscovery.instanceOf('wonders@2'), '2');
    expect(RunnerDiscovery.instanceOf('odd@x'), 'x');
    expect(RunnerDiscovery.instanceOf('wonders@tablet'), 'tablet');
  });

  test('a built-in device registers with its id, label and size', () {
    final config = CustomDeviceConfig.forDevice(
      RaccoonDevice.tablet,
      deviceHelper: '/h',
      platform: 'linux-x64',
    );
    expect(config.id, 'raccoon-tablet');
    expect(config.label, 'Raccoon Tablet');
    final json = config.toJson();
    expect(json['install'], [
      '/h',
      'install',
      '--instance',
      'tablet',
      r'${localPath}',
      r'${appName}',
    ]);
    expect(json['runDebug'], [
      '/h',
      'run',
      '--instance',
      'tablet',
      '--size',
      '820x1180@2',
      r'${appName}',
      r'${engineOptions}',
    ]);
    // The first device and a second run have no size of their own.
    expect(
      CustomDeviceConfig.forDevice(
        RaccoonDevice.host,
        deviceHelper: '/h',
        platform: 'linux-x64',
      ).toJson()['runDebug'],
      ['/h', 'run', r'${appName}', r'${engineOptions}'],
    );
    expect(
      CustomDeviceConfig(
        deviceHelper: '/h',
        instance: '2',
        platform: 'linux-x64',
      ).label,
      'Raccoon 2',
    );
    expect(RaccoonDevice.forKey('phone')?.sizeArgument, '390x844@3');
    expect(RaccoonDevice.forKey('nope'), isNull);
    expect(RaccoonDevice.all.map((d) => d.id), [
      'raccoon',
      'raccoon-2',
      'raccoon-phone',
      'raccoon-tablet',
      'raccoon-desktop',
    ]);
  });
}

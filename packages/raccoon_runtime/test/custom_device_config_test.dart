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
      CustomDevicesFile.forHost({
        'XDG_CONFIG_HOME': '/xdg',
        'HOME': '/h',
      }, operatingSystem: 'linux').path,
      '/xdg/flutter/custom_devices.json',
    );
    expect(
      CustomDevicesFile.forHost({'HOME': '/h'}, operatingSystem: 'macos').path,
      '/h/.config/flutter/custom_devices.json',
    );
  });

  test('resolves the tool config path from APPDATA on Windows', () {
    expect(
      CustomDevicesFile.forHost({
        'APPDATA': r'C:\Users\me\AppData\Roaming',
        'HOME': '/h',
      }, operatingSystem: 'windows').path,
      r'C:\Users\me\AppData\Roaming\.flutter_custom_devices.json',
    );
  });

  test('starts the helper with Git Bash on Windows', () {
    final present = {
      r'C:\Windows\System32\bash.exe',
      r'D:\Tools\Git\mingw64\bin\git.exe',
      r'D:\Tools\Git\bin\bash.exe',
    };
    expect(
      CustomDeviceConfig.gitBashFor({
        'PATH': r'C:\Windows\System32;D:\Tools\Git\mingw64\bin',
      }, present.contains),
      r'D:\Tools\Git\bin\bash.exe',
    );
    expect(
      CustomDeviceConfig.gitBashFor({
        'PATH': r'C:\Windows\System32',
      }, present.contains),
      r'C:\Program Files\Git\bin\bash.exe',
    );

    final config = CustomDeviceConfig(
      deviceHelper: r'C:\r\tool\raccoon-device',
      launcher: [r'C:\Git\bin\bash.exe'],
    );
    final json = config.toJson();
    expect(json['ping'], [
      r'C:\Git\bin\bash.exe',
      r'C:\r\tool\raccoon-device',
      'ping',
    ]);
    expect((json['runDebug'] as List).take(3), [
      r'C:\Git\bin\bash.exe',
      r'C:\r\tool\raccoon-device',
      'run',
    ]);
    final file = CustomDevicesFile(p.join(temp.path, 'devices.json'))
      ..upsert(config);
    expect(file.helperOf('raccoon'), r'C:\r\tool\raccoon-device');
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
        launcher: const [],
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

  // #132: one malformed file threw from every read, which kept the
  // simulator's setup spinning.
  test(
    'a file that is not JSON reads as no devices and is not overwritten',
    () {
      final path = p.join(temp.path, 'custom_devices.json');
      File(path).writeAsStringSync('{"custom-devices": [');
      final file = CustomDevicesFile(path);
      expect(file.ids(), isEmpty);
      expect(file.helperOf('raccoon'), isNull);
      expect(
        () =>
            file.upsert(CustomDeviceConfig(deviceHelper: '/h/raccoon-device')),
        throwsFormatException,
      );
      expect(() => file.remove('raccoon'), throwsFormatException);
      expect(File(path).readAsStringSync(), '{"custom-devices": [');
    },
  );

  test('a write keeps the file\'s other keys', () {
    final path = p.join(temp.path, 'custom_devices.json');
    File(path).writeAsStringSync(
      jsonEncode({
        r'$schema': 'https://example.com/s.json',
        'custom-devices': [],
      }),
    );
    final file = CustomDevicesFile(path);
    file.upsert(CustomDeviceConfig(deviceHelper: '/h/raccoon-device'));
    file.remove('raccoon');
    final decoded = jsonDecode(File(path).readAsStringSync()) as Map;
    expect(decoded[r'$schema'], 'https://example.com/s.json');
    expect(decoded['custom-devices'], isEmpty);
  });

  // #137: the rename replaced a dotfiles manager's link with a file.
  test(
    'a write through a link lands in the linked file',
    () {
      final dotfiles = Directory(p.join(temp.path, 'dotfiles'))..createSync();
      final tracked = File(p.join(dotfiles.path, 'devices.json'))
        ..writeAsStringSync('{"custom-devices": []}');
      final path = p.join(temp.path, 'custom_devices.json');
      Link(path).createSync(p.join('dotfiles', 'devices.json'));
      CustomDevicesFile(
        path,
      ).upsert(CustomDeviceConfig(deviceHelper: '/h/raccoon-device'));
      expect(FileSystemEntity.isLinkSync(path), isTrue);
      expect(tracked.readAsStringSync(), contains('raccoon'));
      expect(CustomDevicesFile(path).ids(), ['raccoon']);
    },
    skip: switch (Platform.isWindows) {
      true => 'file links need privileges on Windows',
      false => false,
    },
  );

  test('a write lands whole, with nothing left beside the file', () {
    final file = CustomDevicesFile(p.join(temp.path, 'tool', 'devices.json'));
    file.upsert(CustomDeviceConfig(deviceHelper: '/h/raccoon-device'));
    file.upsert(
      CustomDeviceConfig.forDevice(
        RaccoonDevice.tablet,
        deviceHelper: '/h/raccoon-device',
      ),
    );
    expect(file.ids(), ['raccoon', 'raccoon-tablet']);
    expect(
      Directory(
        p.join(temp.path, 'tool'),
      ).listSync().map((e) => p.basename(e.path)),
      ['devices.json'],
    );
  });

  test('remove takes one entry out and says whether it was there', () {
    final file = CustomDevicesFile(p.join(temp.path, 'custom_devices.json'));
    file.upsert(CustomDeviceConfig(deviceHelper: '/h/raccoon-device'));
    file.upsert(
      CustomDeviceConfig.forDevice(
        RaccoonDevice.tablet,
        deviceHelper: '/h/raccoon-device',
      ),
    );
    expect(file.remove('raccoon-tablet'), isTrue);
    expect(file.ids(), ['raccoon']);
    expect(file.remove('raccoon-tablet'), isFalse);
    expect(file.remove('raccoon'), isTrue);
    expect(file.ids(), isEmpty);
  });

  test('a device of the user\'s own keeps its size and label in the file', () {
    final file = CustomDevicesFile(p.join(temp.path, 'custom_devices.json'));
    final ipad = RaccoonDevice.custom(
      'ipad',
      size: '1024x1366@2',
      label: 'iPad',
    );
    final config = CustomDeviceConfig.forDevice(ipad, deviceHelper: '/h/rd');
    expect(config.size, '1024x1366@2');
    expect(config.toJson()['runDebug'], contains('--size'));
    file.upsert(config);
    expect(file.sizeOf('raccoon-ipad'), '1024x1366@2');
    expect(file.labelOf('raccoon-ipad'), 'iPad');
    file.upsert(CustomDeviceConfig(deviceHelper: '/h/rd'));
    expect(file.sizeOf('raccoon'), isNull);
    expect(file.labelOf('raccoon'), 'Raccoon');
    expect(file.sizeOf('raccoon-nobody'), isNull);
  });

  test('the helper of an entry is read off its ping command', () {
    final file = CustomDevicesFile(p.join(temp.path, 'custom_devices.json'));
    expect(file.helperOf('raccoon'), isNull);
    file.upsert(CustomDeviceConfig(deviceHelper: '/h/raccoon-device'));
    expect(file.helperOf('raccoon'), '/h/raccoon-device');
    expect(file.helperOf('raccoon-2'), isNull);
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
    final config = CustomDeviceConfig(
      deviceHelper: '/h',
      instance: '2',
      launcher: const [],
    );
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
    final first =
        CustomDeviceConfig(deviceHelper: '/h', launcher: const []).toJson();
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
      launcher: const [],
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
        launcher: const [],
      ).toJson()['runDebug'],
      ['/h', 'run', r'${appName}', r'${engineOptions}'],
    );
    expect(
      CustomDeviceConfig(
        deviceHelper: '/h',
        instance: '2',
        platform: 'linux-x64',
        launcher: const [],
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

  test('the tool\'s settings say whether it lists custom devices', () {
    expect(
      FlutterSettings.forHost({'HOME': '/h'}, operatingSystem: 'macos').path,
      '/h/.config/flutter/settings',
    );
    expect(
      FlutterSettings.forHost({
        'APPDATA': r'C:\Users\me\AppData\Roaming',
      }, operatingSystem: 'windows').path,
      r'C:\Users\me\AppData\Roaming\.flutter_settings',
    );
    final temp = Directory.systemTemp.createTempSync('raccoon_settings');
    addTearDown(() => temp.deleteSync(recursive: true));
    final settings = FlutterSettings('${temp.path}/settings');
    expect(settings.customDevicesEnabled, isFalse);
    File(settings.path).writeAsStringSync('{"enable-custom-devices": true}');
    expect(settings.customDevicesEnabled, isTrue);
    File(settings.path).writeAsStringSync('not json');
    expect(settings.customDevicesEnabled, isFalse);
  });
}

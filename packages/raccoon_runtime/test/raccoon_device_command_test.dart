import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Runs bin/raccoon_device.dart in [directory], its custom devices file
/// under [config].
Future<ProcessResult> _run(
  List<String> arguments, {
  required String directory,
  required String config,
}) => Process.run(
  Platform.resolvedExecutable,
  [p.join(Directory.current.path, 'bin', 'raccoon_device.dart'), ...arguments],
  workingDirectory: directory,
  // A home of its own: a ~/.flutter_custom_devices.json there would win.
  environment: {
    'XDG_CONFIG_HOME': config,
    'APPDATA': config,
    'HOME': p.dirname(config),
  },
);

void main() {
  late Directory temp;
  late String config;
  late Directory project;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('raccoon_device_command');
    config = p.join(temp.path, 'config');
    project = Directory(p.join(temp.path, 'project'))..createSync();
  });
  tearDown(() => temp.deleteSync(recursive: true));

  File devicesFile() =>
      Platform.isWindows
          ? File(p.join(config, '.flutter_custom_devices.json'))
          : File(p.join(config, 'custom_devices.json'));

  test('setup writes the helper as an absolute path', () async {
    // Flutter runs the helper from the project's directory, where a
    // relative path names nothing.
    File(p.join(project.path, 'tool', 'raccoon-device'))
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\n');
    final result = await _run(
      ['setup', '--helper', p.join('tool', 'raccoon-device')],
      directory: project.path,
      config: config,
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final written = devicesFile().readAsStringSync();
    final absolute = p.join(
      project.resolveSymbolicLinksSync(),
      'tool',
      'raccoon-device',
    );
    expect(
      written.contains(absolute.replaceAll(r'\', r'\\')) ||
          written.contains(
            p
                .join(project.path, 'tool', 'raccoon-device')
                .replaceAll(r'\', r'\\'),
          ),
      isTrue,
      reason: written,
    );
  });

  test('setup refuses a helper that is not there', () async {
    final result = await _run(
      ['setup', '--helper', 'nowhere/raccoon-device'],
      directory: project.path,
      config: config,
    );
    expect(result.exitCode, 1);
    expect('${result.stderr}', contains('no helper at'));
    expect(devicesFile().existsSync(), isFalse);
  });
}

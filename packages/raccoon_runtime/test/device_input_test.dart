import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('keys by name, whatever their case and separators', () {
    expect(RaccoonKey.named('Enter'), same(RaccoonKey.enter));
    expect(RaccoonKey.named('arrow_down'), same(RaccoonKey.arrowDown));
    expect(RaccoonKey.named('ArrowDown'), same(RaccoonKey.arrowDown));
    expect(RaccoonKey.named('page-up'), same(RaccoonKey.pageUp));
    expect(RaccoonKey.named('ctrl'), same(RaccoonKey.control));
    expect(RaccoonKey.named('cmd'), same(RaccoonKey.meta));
    expect(RaccoonKey.named('x').physical, 0x0007001b);
    expect(() => RaccoonKey.named('hyper'), throwsArgumentError);
    for (final name in RaccoonKey.keyNames) {
      expect(() => RaccoonKey.named(name), returnsNormally, reason: name);
    }
  });

  test('a runner log tells the runner\'s lines from the app\'s', () {
    final temp = Directory.systemTemp.createTempSync('runner_log');
    try {
      final log = RunnerLog(temp.path);
      expect(log.read('hello@phone'), isEmpty);
      log.fileOf('hello@phone')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          '15:41:51.445 The Dart VM service is listening on http://x/\n'
          '15:41:51.622 🦝 first frame 236 ms after launch\n'
          '\n'
          '15:41:51.700 flutter: hello\n',
        );
      expect(
        [for (final line in log.read('hello@phone')) line.source],
        [DeviceLogSource.app, DeviceLogSource.runner, DeviceLogSource.app],
      );
      expect(
        RunnerLog.forHost({'XDG_DATA_HOME': temp.path}).directory,
        p.join(temp.path, 'raccoon', 'data'),
      );
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  test(
    'a runner line says why a plugin failed; the next line is the app\'s',
    () {
      // The reason is on the runner's line (#407): a line after it, indented
      // as the runner's second line once was, is the app's own.
      final lines = [
        for (final text in [
          '12:00:00.100 🦝 plugin ffmpeg_kit_flutter_new_min not built: needs '
              'the development files of json-glib-1.0, as flutter run -d linux '
              'does: sudo apt install libjson-glib-dev; see .../build.log',
          '12:00:00.120 🦝 plugin nowhere not loaded: libnowhere_plugin.so: '
              'cannot open shared object file: No such file or directory',
          '12:00:00.200      flutter: indented by the app',
          '12:00:00.300 flutter: hello',
        ])
          DeviceLogLine.output(text),
      ];
      expect(
        [for (final line in lines) line.source],
        [
          DeviceLogSource.runner,
          DeviceLogSource.runner,
          DeviceLogSource.app,
          DeviceLogSource.app,
        ],
      );
      expect(lines.first.text, contains('sudo apt install libjson-glib-dev'));
    },
  );

  test('an indented line with no runner line before it is the app\'s', () {
    for (final text in [
      '     needs the development files of json-glib-1.0',
      '12:00:00.000      needs the development files of json-glib-1.0',
      '\tat main (main.dart:3)',
    ]) {
      expect(DeviceLogSource.of(text), DeviceLogSource.app, reason: text);
    }
  });
}

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
}

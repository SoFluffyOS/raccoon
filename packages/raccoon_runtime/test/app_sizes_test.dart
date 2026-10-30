import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('the sizes live where the helper reads them', () {
    expect(
      AppSizes.forHost({'XDG_DATA_HOME': '/data'}).directory,
      p.join('/data', 'raccoon', 'data'),
    );
    expect(
      AppSizes.forHost({'HOME': '/home/me'}).directory,
      p.join('/home/me', '.local', 'share', 'raccoon', 'data'),
    );
  });

  test('a saved size reads back, as --size writes it', () {
    final temp = Directory.systemTemp.createTempSync('raccoon_sizes');
    addTearDown(() => temp.deleteSync(recursive: true));
    final sizes = AppSizes(temp.path);
    expect(sizes.read('wonders'), isNull);

    sizes.save('wonders', width: 390, height: 844, pixelRatio: 3);
    sizes.save('wonders@tablet', width: 360, height: 800, pixelRatio: 2.625);

    expect(
      File(p.join(temp.path, 'wonders', 'size')).readAsStringSync(),
      '390x844@3\n',
    );
    expect(sizes.read('wonders'), (width: 390, height: 844, pixelRatio: 3.0));
    expect(sizes.read('wonders@tablet')?.pixelRatio, 2.625);
  });

  test('a size that can\'t be read is none', () {
    final temp = Directory.systemTemp.createTempSync('raccoon_sizes');
    addTearDown(() => temp.deleteSync(recursive: true));
    final sizes = AppSizes(temp.path);
    File(p.join(temp.path, 'wonders', 'size'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([0xff, 0xfe, 0x33]);
    expect(sizes.read('wonders'), isNull);
  });
}

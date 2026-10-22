import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('the built-in devices carry their keys, ids and sizes', () {
    expect(RaccoonDevice.host.id, 'raccoon');
    expect(RaccoonDevice.second.id, 'raccoon-2');
    expect(RaccoonDevice.tablet.sizeArgument, '820x1180@2');
    expect(RaccoonDevice.presets.map((d) => d.key), [
      'phone',
      'tablet',
      'desktop',
    ]);
    expect(RaccoonDevice.forKey('phone'), same(RaccoonDevice.phone));
    expect(RaccoonDevice.forKey('ipad'), isNull);
  });

  test('a size reads as width, height and ratio', () {
    expect(RaccoonDevice.parseSize('390x844@3'), (
      width: 390,
      height: 844,
      pixelRatio: 3.0,
    ));
    expect(RaccoonDevice.parseSize(' 1024x1366 '), (
      width: 1024,
      height: 1366,
      pixelRatio: 1.0,
    ));
    expect(RaccoonDevice.parseSize('360x800@2.625')?.pixelRatio, 2.625);
    expect(RaccoonDevice.parseSize('390'), isNull);
    expect(RaccoonDevice.parseSize('0x10@1'), isNull);
    expect(RaccoonDevice.parseSize('390x844@0'), isNull);
  });

  test('a device of the user\'s own gets its id, a label and the size', () {
    final ipad = RaccoonDevice.custom('ipad', size: '1024x1366@2');
    expect(ipad.id, 'raccoon-ipad');
    expect(ipad.label, 'Raccoon Ipad');
    expect(ipad.width, 1024);
    expect(ipad.pixelRatio, 2);
    expect(ipad.sizeArgument, '1024x1366@2');

    final named = RaccoonDevice.custom('fold', label: 'Fold, open');
    expect(named.label, 'Fold, open');
    expect(named.hasSize, isFalse);
    expect(named.sizeArgument, isNull);

    expect(() => RaccoonDevice.custom('bad key'), throwsArgumentError);
    expect(() => RaccoonDevice.custom('x', size: 'big'), throwsArgumentError);
  });
}

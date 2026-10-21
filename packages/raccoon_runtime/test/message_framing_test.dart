import 'dart:typed_data';

import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('frame prepends a little-endian length', () {
    final framed = MessageFraming.frame([9, 8, 7]);

    expect(framed, [3, 0, 0, 0, 9, 8, 7]);
  });

  test('unframer reassembles messages split across chunks', () {
    final unframer = MessageUnframer();
    final first = MessageFraming.frame([1, 2]);
    final second = MessageFraming.frame([3]);
    final all = Uint8List.fromList([...first, ...second]);

    expect(unframer.add(all.sublist(0, 3)), isEmpty);
    expect(unframer.add(all.sublist(3, 7)), [
      [1, 2],
    ]);
    expect(unframer.add(all.sublist(7)), [
      [3],
    ]);
  });

  test('unframer returns several messages from one chunk', () {
    final unframer = MessageUnframer();
    final chunk = [
      ...MessageFraming.frame([1]),
      ...MessageFraming.frame([2]),
    ];

    expect(unframer.add(chunk), [
      [1],
      [2],
    ]);
  });
}

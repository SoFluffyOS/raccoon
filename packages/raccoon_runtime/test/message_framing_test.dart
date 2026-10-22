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

  test('unframer handles a large message in many small chunks', () {
    final unframer = MessageUnframer();
    final payload = List<int>.generate(300000, (i) => i % 251);
    final framed = MessageFraming.frame(payload);
    final out = <Uint8List>[];
    for (var offset = 0; offset < framed.length; offset += 1000) {
      final end = offset + 1000 < framed.length ? offset + 1000 : framed.length;
      out.addAll(unframer.add(framed.sublist(offset, end)));
    }

    expect(out, hasLength(1));
    expect(out.single, payload);
  });

  test('unframer copes with a prefix split across chunks', () {
    final unframer = MessageUnframer();
    final framed = MessageFraming.frame([7, 8, 9]);

    expect(unframer.add(framed.sublist(0, 2)), isEmpty);
    expect(unframer.add(framed.sublist(2, 5)), isEmpty);
    expect(unframer.add(framed.sublist(5)), [
      [7, 8, 9],
    ]);
  });
}

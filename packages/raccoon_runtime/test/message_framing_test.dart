import 'dart:math';
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

  test('a message whole in one chunk is a view of it, not a copy', () {
    // #227: a frame that arrives in one read costs no copy here.
    final chunk = Uint8List.fromList([
      ...MessageFraming.frame([1, 2, 3]),
      ...MessageFraming.frame([4]),
    ]);

    final payloads = MessageUnframer().add(chunk);

    expect(payloads, [
      [1, 2, 3],
      [4],
    ]);
    chunk[MessageFraming.prefixLength] = 9;
    expect(payloads.first.first, 9);
  });

  test('a length past the most a message may be is an error', () {
    final prefix = Uint8List(4);
    ByteData.sublistView(
      prefix,
    ).setUint32(0, MessageFraming.maxLength + 1, Endian.little);

    expect(() => MessageUnframer().add(prefix), throwsFormatException);
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

  test('any split of a stream gives back its messages, whole and in order', () {
    // Messages of every size class (empty, small, past a socket read),
    // cut at random places, a fixed seed so a failure repeats.
    final random = Random(20261025);
    for (var round = 0; round < 200; round++) {
      final messages = [
        for (var i = 0; i < 1 + random.nextInt(8); i++)
          Uint8List.fromList(
            List.generate(
              [0, 1, 3, 255, 4096, 70000][random.nextInt(6)],
              (k) => (k * 7 + i) & 0xff,
            ),
          ),
      ];
      final stream = [for (final m in messages) ...MessageFraming.frame(m)];
      final unframer = MessageUnframer();
      final out = <Uint8List>[];
      var at = 0;
      while (at < stream.length) {
        final take = 1 + random.nextInt(9000);
        final end = at + take > stream.length ? stream.length : at + take;
        out.addAll(unframer.add(stream.sublist(at, end)));
        at = end;
      }
      expect(out.length, messages.length, reason: 'round $round');
      for (var i = 0; i < messages.length; i++) {
        expect(out[i], messages[i], reason: 'round $round, message $i');
      }
    }
  });
}

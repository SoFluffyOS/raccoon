import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:protobuf/protobuf.dart' show InvalidProtocolBufferException;
import 'package:raccoon/raccoon.dart';
import 'package:raccoon_runtime/src/runner_message_decoder.dart';
import 'package:test/test.dart';

void main() {
  RunnerMessage everyField() => RunnerMessage(
    frame: Frame(
      sequence: Int64(1) << 40,
      width: 1920,
      height: 1080,
      rowBytes: 1920 * 4,
      format: PixelFormat.PIXEL_FORMAT_BGRA8888,
      pixels: List<int>.generate(64, (i) => i),
      timestampMicros: Int64(123456789),
      inSharedBuffer: true,
      bufferIndex: 2,
      inGpuBuffer: true,
      gpuGeneration: 7,
    ),
  );

  test('a frame decodes as protobuf decodes it', () {
    final payload = everyField().writeToBuffer();
    expect(decodeRunnerMessage(payload), RunnerMessage.fromBuffer(payload));
  });

  test('a frame\'s pixels are the payload\'s own bytes, not a copy', () {
    final payload = everyField().writeToBuffer();
    final pixels = decodeRunnerMessage(payload).frame.pixels;
    final at = payload.indexOf(63);
    payload[at] = 200;
    expect(pixels[63], 200);
  });

  test('every other message goes through protobuf', () {
    for (final message in [
      RunnerMessage(hello: RunnerHello(protocolVersion: 3, pid: 9)),
      RunnerMessage(busy: Busy(pid: 4)),
      RunnerMessage(log: LogLine(tag: 'app', message: 'hi')),
      RunnerMessage(frame: Frame()),
    ]) {
      final payload = message.writeToBuffer();
      expect(decodeRunnerMessage(payload), message);
    }
  });

  test('a frame with a field this does not know goes through protobuf', () {
    // Field 12, a varint: a later runner's.
    final known = everyField().writeToBuffer();
    final frameStart = 1 + _varintLength(known, 1);
    final frame = known.sublist(frameStart);
    final withNew = [...frame, 12 << 3, 5];
    final payload = Uint8List.fromList([
      2 << 3 | 2,
      ..._varint(withNew.length),
      ...withNew,
    ]);
    final decoded = decodeRunnerMessage(payload);
    expect(decoded, RunnerMessage.fromBuffer(payload));
    expect(decoded.frame.width, 1920);
  });

  test('a broken frame fails as protobuf fails it', () {
    final payload = everyField().writeToBuffer();
    final cut = Uint8List.sublistView(payload, 0, payload.length - 10);
    expect(
      () => decodeRunnerMessage(cut),
      throwsA(isA<InvalidProtocolBufferException>()),
    );
  });
}

int _varintLength(Uint8List bytes, int start) {
  var i = start;
  while (bytes[i] & 0x80 != 0) {
    i++;
  }
  return i - start + 1;
}

List<int> _varint(int value) {
  final out = <int>[];
  while (value >= 0x80) {
    out.add(value & 0x7f | 0x80);
    value >>= 7;
  }
  out.add(value);
  return out;
}

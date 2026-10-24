import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raccoon/raccoon.dart' as rc;
import 'package:raccoon_view/raccoon_view.dart';

void main() {
  test(
    'decodes a BGRA frame into an image of the right size and colour',
    () async {
      final frame = rc.Frame(
        sequence: Int64(1),
        width: 2,
        height: 1,
        rowBytes: 8,
        format: rc.PixelFormat.PIXEL_FORMAT_BGRA8888,
        pixels: [0xE5, 0x88, 0x1E, 0xFF, 0x35, 0x39, 0xE5, 0xFF],
      );

      final image = await decodeFrame(frame);
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);

      expect(image.width, 2);
      expect(image.height, 1);
      expect(rgba?.buffer.asUint8List().sublist(0, 4), [
        0x1E,
        0x88,
        0xE5,
        0xFF,
      ]);
      expect(rgba?.buffer.asUint8List().sublist(4, 8), [
        0xE5,
        0x39,
        0x35,
        0xFF,
      ]);
    },
  );

  // #106: what protobuf hands over, a view into the message's bytes.
  test('decodes pixels that come as a view into a larger buffer', () async {
    final buffer = Uint8List.fromList([
      0, 0, 0, 0, // before the frame
      0xE5, 0x88, 0x1E, 0xFF, 0x35, 0x39, 0xE5, 0xFF,
    ]);
    final frame = rc.Frame(
      sequence: Int64(1),
      width: 2,
      height: 1,
      rowBytes: 8,
      format: rc.PixelFormat.PIXEL_FORMAT_BGRA8888,
      pixels: Uint8List.sublistView(buffer, 4),
    );

    final image = await decodeFrame(frame);
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);

    expect(rgba?.buffer.asUint8List(), [
      0x1E,
      0x88,
      0xE5,
      0xFF,
      0xE5,
      0x39,
      0x35,
      0xFF,
    ]);
  });

  // #133: a frame its pixels can't fill never called back, and every frame
  // after it waited.
  test(
    'a frame its pixels cannot fill fails instead of never ending',
    () async {
      final short = rc.Frame(
        sequence: Int64(1),
        width: 4,
        height: 4,
        rowBytes: 16,
        format: rc.PixelFormat.PIXEL_FORMAT_BGRA8888,
        pixels: List.filled(20, 0),
      );
      await expectLater(decodeFrame(short), throwsArgumentError);
      final empty = rc.Frame(sequence: Int64(1));
      await expectLater(decodeFrame(empty), throwsArgumentError);
    },
  );

  test('rows lie end to end when the frame does not say', () async {
    final frame = rc.Frame(
      sequence: Int64(1),
      width: 2,
      height: 2,
      format: rc.PixelFormat.PIXEL_FORMAT_RGBA8888,
      pixels: List.filled(16, 0xFF),
    );
    final image = await decodeFrame(frame);
    expect(image.height, 2);
    image.dispose();
  });
}

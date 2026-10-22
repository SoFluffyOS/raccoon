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
}

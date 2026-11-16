import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:raccoon/raccoon.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

/// A 4 x 2 frame in [format], every pixel (r, g, b), rows padded to 20
/// bytes.
Frame _frame(PixelFormat format, int r, int g, int b) {
  final pixels = Uint8List(20 * 2);
  for (var y = 0; y < 2; y++) {
    for (var x = 0; x < 4; x++) {
      final at = y * 20 + x * 4;
      final bgra = format != PixelFormat.PIXEL_FORMAT_RGBA8888;
      pixels
        ..[at] = bgra ? b : r
        ..[at + 1] = g
        ..[at + 2] = bgra ? r : b
        ..[at + 3] = 0xFF;
    }
  }
  return Frame(
    width: 4,
    height: 2,
    rowBytes: 20,
    format: format,
    pixels: pixels,
  );
}

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('frame_image'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('a frame decodes the same from either byte order', () {
    for (final format in [
      PixelFormat.PIXEL_FORMAT_BGRA8888,
      PixelFormat.PIXEL_FORMAT_RGBA8888,
    ]) {
      final image = frameImage(_frame(format, 0x1E, 0x88, 0xE5));
      final pixel = image.getPixel(3, 1);
      expect((image.width, image.height), (4, 2));
      expect((pixel.r, pixel.g, pixel.b, pixel.a), (0x1E, 0x88, 0xE5, 0xFF));
    }
  });

  test('a frame in a GPU buffer has no image', () {
    expect(() => frameImage(Frame(inGpuBuffer: true)), throwsStateError);
  });

  test('a frame as PNG decodes to its pixels', () async {
    final png = await framePng(
      _frame(PixelFormat.PIXEL_FORMAT_BGRA8888, 1, 2, 3),
    );
    final decoded = img.decodePng(png)!;
    final pixel = decoded.getPixel(0, 0);
    expect((pixel.r, pixel.g, pixel.b), (1, 2, 3));
  });

  test('a golden is written when missing, then matched, and a mismatch '
      'leaves the actual beside it', () async {
    final golden = p.join(temp.path, 'goldens', 'box.png');
    final actual = p.join(temp.path, 'goldens', 'box.actual.png');
    final blue = frameImage(
      _frame(PixelFormat.PIXEL_FORMAT_BGRA8888, 0, 0, 255),
    );
    final created = await compareToGoldenFile(blue, golden, update: false);
    expect(created.created, isTrue);
    expect(File(golden).existsSync(), isTrue);

    final same = await compareToGoldenFile(blue, golden, update: false);
    expect(
      (same.matches, same.created, same.differingPixels),
      (true, false, 0),
    );

    final near = frameImage(
      _frame(PixelFormat.PIXEL_FORMAT_BGRA8888, 0, 2, 255),
    );
    final strict = await compareToGoldenFile(near, golden, update: false);
    expect(strict.matches, isFalse);
    expect(strict.differingPixels, 8);
    expect(strict.largestDifference, 2);
    expect(File(actual).existsSync(), isTrue);
    await expectLater(
      expectGoldenFile(near, golden),
      throwsA(isA<GoldenMismatch>()),
    );

    final tolerant = await compareToGoldenFile(
      near,
      golden,
      channelTolerance: 2,
      update: false,
    );
    expect(tolerant.matches, isTrue);
    expect(File(actual).existsSync(), isFalse);

    final some = await compareToGoldenFile(
      near,
      golden,
      maxDifferingRatio: 1,
      update: false,
    );
    expect((some.matches, some.differingPixels), (true, 8));
  });

  test('a golden of another size does not match', () async {
    final golden = p.join(temp.path, 'other.png');
    File(
      golden,
    ).writeAsBytesSync(img.encodePng(img.Image(width: 3, height: 3)));
    final result = await compareToGoldenFile(
      frameImage(_frame(PixelFormat.PIXEL_FORMAT_BGRA8888, 0, 0, 0)),
      golden,
      update: false,
    );
    expect(result.matches, isFalse);
    expect(result.why, contains('4x2'));
  });

  test('keys carry Flutter\'s codes', () {
    expect(RaccoonKey.character('a').physical, 0x00070004);
    expect(RaccoonKey.character('A').logical, 0x61);
    expect(RaccoonKey.character('0').physical, 0x00070027);
    expect(RaccoonKey.character('/').physical, 0x00070038);
    expect(RaccoonKey.enter.logical, 0x0010000000d);
    expect(() => RaccoonKey.character('é'), throwsArgumentError);
  });
}

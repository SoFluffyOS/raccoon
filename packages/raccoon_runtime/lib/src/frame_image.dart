import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:raccoon/raccoon.dart';

/// A frame's pixels as an RGBA image, whichever byte order the runner sent
/// them in (BGRA read back from a GPU and from the software renderer on
/// Linux and Windows, RGBA on macOS). The image has pixels of its own: the
/// frame's may be reused once it is read.
///
/// A frame in a GPU buffer has none; ask for pixels first
/// ([RunnerClient.wantPixels]).
img.Image frameImage(Frame frame) {
  if (frame.inGpuBuffer) {
    throw StateError('frame ${frame.sequence} is in a GPU buffer: no pixels');
  }
  final pixels = switch (frame.pixels) {
    final Uint8List bytes => bytes,
    final bytes => Uint8List.fromList(bytes),
  };
  if (frame.width <= 0 ||
      frame.height <= 0 ||
      frame.rowBytes < frame.width * 4 ||
      pixels.length < frame.rowBytes * frame.height) {
    throw StateError(
      'frame ${frame.sequence} says ${frame.width}x${frame.height} in rows of '
      '${frame.rowBytes} bytes but has ${pixels.length}',
    );
  }
  return img.Image.fromBytes(
    width: frame.width,
    height: frame.height,
    bytes: pixels.buffer,
    bytesOffset: pixels.offsetInBytes,
    rowStride: frame.rowBytes,
    numChannels: 4,
    order: switch (frame.format) {
      PixelFormat.PIXEL_FORMAT_RGBA8888 => img.ChannelOrder.rgba,
      _ => img.ChannelOrder.bgra,
    },
  ).clone();
}

/// [image] as PNG bytes, encoded on another isolate: a phone's frame takes
/// a few hundred milliseconds.
Future<Uint8List> encodePngOf(img.Image image) =>
    Isolate.run(() => img.encodePng(image));

/// [frame] as PNG bytes; see [frameImage].
Future<Uint8List> framePng(Frame frame) => encodePngOf(frameImage(frame));

/// How an image compared with a golden PNG.
final class GoldenResult {
  const GoldenResult({
    required this.golden,
    required this.matches,
    this.created = false,
    this.differingPixels = 0,
    this.totalPixels = 0,
    this.largestDifference = 0,
    this.actual,
    this.why,
  });

  /// The golden file.
  final String golden;

  /// Whether the image is the golden, within the tolerances.
  final bool matches;

  /// Whether there was no golden (or an update was asked for) and the
  /// image became it.
  final bool created;

  /// Pixels with a channel further from the golden's than the tolerance.
  final int differingPixels;

  /// The pixels compared.
  final int totalPixels;

  /// The largest difference in any channel of any pixel, 0 to 255.
  final int largestDifference;

  /// Where the image was written on a mismatch: beside the golden, as
  /// `<name>.actual.png`.
  final String? actual;

  /// Why it does not match, for a failure message.
  final String? why;

  @override
  String toString() => switch ((matches, created)) {
    (true, true) => 'wrote golden $golden',
    (true, false) =>
      'matches $golden ($differingPixels of $totalPixels pixels differ)',
    _ => 'does not match $golden: $why${actual == null ? '' : '; see $actual'}',
  };
}

/// Thrown by [expectGoldenFile] on a mismatch.
final class GoldenMismatch implements Exception {
  const GoldenMismatch(this.result);

  final GoldenResult result;

  @override
  String toString() => 'GoldenMismatch: $result';
}

/// Compares [image] with the PNG at [golden].
///
/// A pixel differs when one of its channels is more than
/// [channelTolerance] away from the golden's; the image matches while at
/// most [maxDifferingRatio] of its pixels differ. Without a golden, or with
/// `RACCOON_UPDATE_GOLDENS=1` in the environment (or [update]), the image
/// is written as the golden and matches. On a mismatch it is written beside
/// the golden as `<name>.actual.png`; on a match a stale one goes.
Future<GoldenResult> compareToGoldenFile(
  img.Image image,
  String golden, {
  int channelTolerance = 0,
  double maxDifferingRatio = 0,
  bool? update,
}) async {
  final file = File(golden);
  final actualFile = File(_actualPath(golden));
  final updating =
      update ?? Platform.environment['RACCOON_UPDATE_GOLDENS'] == '1';
  if (updating || !file.existsSync()) {
    await file.parent.create(recursive: true);
    await file.writeAsBytes(await encodePngOf(image));
    if (actualFile.existsSync()) await actualFile.delete();
    return GoldenResult(golden: golden, matches: true, created: true);
  }
  final bytes = await file.readAsBytes();
  final result = await Isolate.run(
    () => _compare(image, bytes, golden, channelTolerance, maxDifferingRatio),
  );
  if (result.matches) {
    if (actualFile.existsSync()) await actualFile.delete();
    return result;
  }
  await actualFile.writeAsBytes(await encodePngOf(image));
  return GoldenResult(
    golden: golden,
    matches: false,
    differingPixels: result.differingPixels,
    totalPixels: result.totalPixels,
    largestDifference: result.largestDifference,
    actual: actualFile.path,
    why: result.why,
  );
}

/// [compareToGoldenFile], throwing [GoldenMismatch] when the image does not
/// match.
Future<GoldenResult> expectGoldenFile(
  img.Image image,
  String golden, {
  int channelTolerance = 0,
  double maxDifferingRatio = 0,
}) async {
  final result = await compareToGoldenFile(
    image,
    golden,
    channelTolerance: channelTolerance,
    maxDifferingRatio: maxDifferingRatio,
  );
  if (!result.matches) throw GoldenMismatch(result);
  return result;
}

String _actualPath(String golden) {
  final dot = golden.toLowerCase().endsWith('.png') ? golden.length - 4 : -1;
  final stem = dot < 0 ? golden : golden.substring(0, dot);
  return '$stem.actual.png';
}

GoldenResult _compare(
  img.Image image,
  Uint8List goldenBytes,
  String golden,
  int channelTolerance,
  double maxDifferingRatio,
) {
  final expected = img.decodePng(goldenBytes);
  if (expected == null) {
    return GoldenResult(golden: golden, matches: false, why: 'not a PNG');
  }
  if (expected.width != image.width || expected.height != image.height) {
    return GoldenResult(
      golden: golden,
      matches: false,
      why:
          'the image is ${image.width}x${image.height}, the golden '
          '${expected.width}x${expected.height}',
    );
  }
  final a = image.getBytes(order: img.ChannelOrder.rgba);
  // A golden of 8-bit RGBA, whatever the PNG held.
  final b = expected
      .convert(format: img.Format.uint8, numChannels: 4, alpha: 255)
      .getBytes(order: img.ChannelOrder.rgba);
  final total = image.width * image.height;
  var differing = 0;
  var largest = 0;
  for (var i = 0; i + 3 < a.length && i + 3 < b.length; i += 4) {
    var d = 0;
    for (var c = 0; c < 4; c++) {
      final e = (a[i + c] - b[i + c]).abs();
      if (e > d) d = e;
    }
    if (d > largest) largest = d;
    if (d > channelTolerance) differing++;
  }
  final matches = differing <= total * maxDifferingRatio;
  return GoldenResult(
    golden: golden,
    matches: matches,
    differingPixels: differing,
    totalPixels: total,
    largestDifference: largest,
    why:
        matches
            ? null
            : '$differing of $total pixels differ by more than $channelTolerance '
                '(${(differing * 100 / total).toStringAsFixed(3)} %, '
                '${(maxDifferingRatio * 100).toStringAsFixed(3)} % allowed), '
                'by up to $largest',
  );
}

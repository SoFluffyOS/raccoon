import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:raccoon/raccoon.dart' as rc;

/// Turns a runner frame into a [ui.Image] the engine can draw. Throws for
/// a frame its pixels can't fill, or one the engine can't decode: the
/// engine's `decodeImageFromPixels` never answers then, and a decode that
/// never ends would hold up every frame after it (#133).
Future<ui.Image> decodeFrame(rc.Frame frame) async {
  final format = switch (frame.format) {
    rc.PixelFormat.PIXEL_FORMAT_RGBA8888 => ui.PixelFormat.rgba8888,
    _ => ui.PixelFormat.bgra8888,
  };
  // The engine copies the pixels itself; protobuf hands them over as a
  // Uint8List already, so they go on as they are (#106).
  final pixels = switch (frame.pixels) {
    final Uint8List bytes => bytes,
    final bytes => Uint8List.fromList(bytes),
  };
  final width = frame.width;
  final height = frame.height;
  // Unset, rows lie end to end.
  final rowBytes = switch (frame.rowBytes) {
    0 => width * 4,
    final given => given,
  };
  if (width <= 0 || height <= 0 || rowBytes < width * 4) {
    throw ArgumentError('a ${width}x$height frame of $rowBytes bytes a row');
  }
  if (pixels.length < rowBytes * (height - 1) + width * 4) {
    throw ArgumentError(
      'a ${width}x$height frame with only ${pixels.length} bytes',
    );
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: width,
    height: height,
    rowBytes: rowBytes,
    pixelFormat: format,
  );
  try {
    final codec = await descriptor.instantiateCodec();
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  } finally {
    descriptor.dispose();
    buffer.dispose();
  }
}

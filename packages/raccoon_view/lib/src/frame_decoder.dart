import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:raccoon/raccoon.dart' as rc;

/// Turns a runner frame into a [ui.Image] the engine can draw.
Future<ui.Image> decodeFrame(rc.Frame frame) {
  final completer = Completer<ui.Image>();
  final format = switch (frame.format) {
    rc.PixelFormat.PIXEL_FORMAT_RGBA8888 => ui.PixelFormat.rgba8888,
    _ => ui.PixelFormat.bgra8888,
  };
  // decodeImageFromPixels copies the pixels itself; protobuf hands them over
  // as a Uint8List already, so they go on as they are (#106).
  final pixels = switch (frame.pixels) {
    final Uint8List bytes => bytes,
    final bytes => Uint8List.fromList(bytes),
  };
  ui.decodeImageFromPixels(
    pixels,
    frame.width,
    frame.height,
    format,
    completer.complete,
    rowBytes: frame.rowBytes,
  );
  return completer.future;
}

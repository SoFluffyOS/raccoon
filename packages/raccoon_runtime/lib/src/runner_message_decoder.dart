import 'dart:typed_data';

import 'package:protobuf/protobuf.dart';
import 'package:raccoon/raccoon.dart';

/// Decodes a runner's message as [RunnerMessage.fromBuffer] does, but a
/// frame's pixels are a view of [payload] rather than a copy: protobuf
/// copies every bytes field, 8 MB a 1080p frame on the isolate that shows
/// it. [payload] is the message's own buffer (the unframer's), so nothing
/// else writes it. A message that is anything but one frame of the fields
/// known here goes through protobuf.
RunnerMessage decodeRunnerMessage(Uint8List payload) =>
    _frameMessage(payload) ?? RunnerMessage.fromBuffer(payload);

/// The tags (field number << 3 | wire type) of RunnerMessage's frame and
/// of Frame's fields, as runner.proto numbers them.
const _frameTag = 2 << 3 | 2;
const _sequence = 1 << 3;
const _width = 2 << 3;
const _height = 3 << 3;
const _rowBytes = 4 << 3;
const _format = 5 << 3;
const _pixels = 6 << 3 | 2;
const _timestamp = 7 << 3;
const _inSharedBuffer = 8 << 3;
const _bufferIndex = 9 << 3;
const _inGpuBuffer = 10 << 3;
const _gpuGeneration = 11 << 3;

RunnerMessage? _frameMessage(Uint8List payload) {
  if (payload.isEmpty || payload[0] != _frameTag) return null;
  try {
    final outer = CodedBufferReader(payload);
    if (outer.readTag() != _frameTag) return null;
    final fields = outer.readBytesAsView();
    if (!outer.isAtEnd()) return null;
    final reader = CodedBufferReader(fields);
    final frame = Frame();
    while (!reader.isAtEnd()) {
      switch (reader.readTag()) {
        case _sequence:
          frame.sequence = reader.readUint64();
        case _width:
          frame.width = reader.readUint32();
        case _height:
          frame.height = reader.readUint32();
        case _rowBytes:
          frame.rowBytes = reader.readUint32();
        case _format:
          final format = PixelFormat.valueOf(reader.readEnum());
          if (format == null) return null;
          frame.format = format;
        case _pixels:
          frame.pixels = reader.readBytesAsView();
        case _timestamp:
          frame.timestampMicros = reader.readUint64();
        case _inSharedBuffer:
          frame.inSharedBuffer = reader.readBool();
        case _bufferIndex:
          frame.bufferIndex = reader.readUint32();
        case _inGpuBuffer:
          frame.inGpuBuffer = reader.readBool();
        case _gpuGeneration:
          frame.gpuGeneration = reader.readUint32();
        default:
          return null;
      }
    }
    return RunnerMessage(frame: frame);
  } on InvalidProtocolBufferException {
    // protobuf says what is wrong with it.
    return null;
  }
}

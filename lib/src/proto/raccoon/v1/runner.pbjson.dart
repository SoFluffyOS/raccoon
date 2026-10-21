// This is a generated file - do not edit.
//
// Generated from raccoon/v1/runner.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports
// ignore_for_file: unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use pointerPhaseDescriptor instead')
const PointerPhase$json = {
  '1': 'PointerPhase',
  '2': [
    {'1': 'POINTER_PHASE_UNSPECIFIED', '2': 0},
    {'1': 'POINTER_PHASE_ADD', '2': 1},
    {'1': 'POINTER_PHASE_REMOVE', '2': 2},
    {'1': 'POINTER_PHASE_HOVER', '2': 3},
    {'1': 'POINTER_PHASE_DOWN', '2': 4},
    {'1': 'POINTER_PHASE_MOVE', '2': 5},
    {'1': 'POINTER_PHASE_UP', '2': 6},
  ],
};

/// Descriptor for `PointerPhase`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List pointerPhaseDescriptor = $convert.base64Decode(
    'CgxQb2ludGVyUGhhc2USHQoZUE9JTlRFUl9QSEFTRV9VTlNQRUNJRklFRBAAEhUKEVBPSU5URV'
    'JfUEhBU0VfQUREEAESGAoUUE9JTlRFUl9QSEFTRV9SRU1PVkUQAhIXChNQT0lOVEVSX1BIQVNF'
    'X0hPVkVSEAMSFgoSUE9JTlRFUl9QSEFTRV9ET1dOEAQSFgoSUE9JTlRFUl9QSEFTRV9NT1ZFEA'
    'USFAoQUE9JTlRFUl9QSEFTRV9VUBAG');

@$core.Deprecated('Use pointerDeviceDescriptor instead')
const PointerDevice$json = {
  '1': 'PointerDevice',
  '2': [
    {'1': 'POINTER_DEVICE_UNSPECIFIED', '2': 0},
    {'1': 'POINTER_DEVICE_MOUSE', '2': 1},
    {'1': 'POINTER_DEVICE_TOUCH', '2': 2},
  ],
};

/// Descriptor for `PointerDevice`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List pointerDeviceDescriptor = $convert.base64Decode(
    'Cg1Qb2ludGVyRGV2aWNlEh4KGlBPSU5URVJfREVWSUNFX1VOU1BFQ0lGSUVEEAASGAoUUE9JTl'
    'RFUl9ERVZJQ0VfTU9VU0UQARIYChRQT0lOVEVSX0RFVklDRV9UT1VDSBAC');

@$core.Deprecated('Use keyKindDescriptor instead')
const KeyKind$json = {
  '1': 'KeyKind',
  '2': [
    {'1': 'KEY_KIND_UNSPECIFIED', '2': 0},
    {'1': 'KEY_KIND_DOWN', '2': 1},
    {'1': 'KEY_KIND_UP', '2': 2},
    {'1': 'KEY_KIND_REPEAT', '2': 3},
  ],
};

/// Descriptor for `KeyKind`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List keyKindDescriptor = $convert.base64Decode(
    'CgdLZXlLaW5kEhgKFEtFWV9LSU5EX1VOU1BFQ0lGSUVEEAASEQoNS0VZX0tJTkRfRE9XThABEg'
    '8KC0tFWV9LSU5EX1VQEAISEwoPS0VZX0tJTkRfUkVQRUFUEAM=');

@$core.Deprecated('Use pixelFormatDescriptor instead')
const PixelFormat$json = {
  '1': 'PixelFormat',
  '2': [
    {'1': 'PIXEL_FORMAT_UNSPECIFIED', '2': 0},
    {'1': 'PIXEL_FORMAT_BGRA8888', '2': 1},
    {'1': 'PIXEL_FORMAT_RGBA8888', '2': 2},
  ],
};

/// Descriptor for `PixelFormat`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List pixelFormatDescriptor = $convert.base64Decode(
    'CgtQaXhlbEZvcm1hdBIcChhQSVhFTF9GT1JNQVRfVU5TUEVDSUZJRUQQABIZChVQSVhFTF9GT1'
    'JNQVRfQkdSQTg4ODgQARIZChVQSVhFTF9GT1JNQVRfUkdCQTg4ODgQAg==');

@$core.Deprecated('Use clientHelloDescriptor instead')
const ClientHello$json = {
  '1': 'ClientHello',
  '2': [
    {'1': 'protocol_version', '3': 1, '4': 1, '5': 13, '10': 'protocolVersion'},
    {'1': 'client_name', '3': 2, '4': 1, '5': 9, '10': 'clientName'},
    {'1': 'shared_buffers', '3': 3, '4': 1, '5': 8, '10': 'sharedBuffers'},
    {'1': 'composes', '3': 5, '4': 1, '5': 8, '10': 'composes'},
    {'1': 'pid', '3': 4, '4': 1, '5': 13, '10': 'pid'},
  ],
};

/// Descriptor for `ClientHello`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List clientHelloDescriptor = $convert.base64Decode(
    'CgtDbGllbnRIZWxsbxIpChBwcm90b2NvbF92ZXJzaW9uGAEgASgNUg9wcm90b2NvbFZlcnNpb2'
    '4SHwoLY2xpZW50X25hbWUYAiABKAlSCmNsaWVudE5hbWUSJQoOc2hhcmVkX2J1ZmZlcnMYAyAB'
    'KAhSDXNoYXJlZEJ1ZmZlcnMSGgoIY29tcG9zZXMYBSABKAhSCGNvbXBvc2VzEhAKA3BpZBgEIA'
    'EoDVIDcGlk');

@$core.Deprecated('Use releaseBufferDescriptor instead')
const ReleaseBuffer$json = {
  '1': 'ReleaseBuffer',
  '2': [
    {'1': 'index', '3': 1, '4': 1, '5': 13, '10': 'index'},
  ],
};

/// Descriptor for `ReleaseBuffer`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List releaseBufferDescriptor = $convert
    .base64Decode('Cg1SZWxlYXNlQnVmZmVyEhQKBWluZGV4GAEgASgNUgVpbmRleA==');

@$core.Deprecated('Use resizeDescriptor instead')
const Resize$json = {
  '1': 'Resize',
  '2': [
    {'1': 'width', '3': 1, '4': 1, '5': 13, '10': 'width'},
    {'1': 'height', '3': 2, '4': 1, '5': 13, '10': 'height'},
    {'1': 'pixel_ratio', '3': 3, '4': 1, '5': 1, '10': 'pixelRatio'},
  ],
};

/// Descriptor for `Resize`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List resizeDescriptor = $convert.base64Decode(
    'CgZSZXNpemUSFAoFd2lkdGgYASABKA1SBXdpZHRoEhYKBmhlaWdodBgCIAEoDVIGaGVpZ2h0Eh'
    '8KC3BpeGVsX3JhdGlvGAMgASgBUgpwaXhlbFJhdGlv');

@$core.Deprecated('Use pointerEventDescriptor instead')
const PointerEvent$json = {
  '1': 'PointerEvent',
  '2': [
    {
      '1': 'phase',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.raccoon.v1.PointerPhase',
      '10': 'phase'
    },
    {'1': 'x', '3': 2, '4': 1, '5': 1, '10': 'x'},
    {'1': 'y', '3': 3, '4': 1, '5': 1, '10': 'y'},
    {'1': 'buttons', '3': 4, '4': 1, '5': 3, '10': 'buttons'},
    {
      '1': 'device',
      '3': 5,
      '4': 1,
      '5': 14,
      '6': '.raccoon.v1.PointerDevice',
      '10': 'device'
    },
    {'1': 'pointer_id', '3': 6, '4': 1, '5': 5, '10': 'pointerId'},
    {'1': 'timestamp_micros', '3': 7, '4': 1, '5': 4, '10': 'timestampMicros'},
    {'1': 'scroll_delta_x', '3': 8, '4': 1, '5': 1, '10': 'scrollDeltaX'},
    {'1': 'scroll_delta_y', '3': 9, '4': 1, '5': 1, '10': 'scrollDeltaY'},
  ],
};

/// Descriptor for `PointerEvent`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List pointerEventDescriptor = $convert.base64Decode(
    'CgxQb2ludGVyRXZlbnQSLgoFcGhhc2UYASABKA4yGC5yYWNjb29uLnYxLlBvaW50ZXJQaGFzZV'
    'IFcGhhc2USDAoBeBgCIAEoAVIBeBIMCgF5GAMgASgBUgF5EhgKB2J1dHRvbnMYBCABKANSB2J1'
    'dHRvbnMSMQoGZGV2aWNlGAUgASgOMhkucmFjY29vbi52MS5Qb2ludGVyRGV2aWNlUgZkZXZpY2'
    'USHQoKcG9pbnRlcl9pZBgGIAEoBVIJcG9pbnRlcklkEikKEHRpbWVzdGFtcF9taWNyb3MYByAB'
    'KARSD3RpbWVzdGFtcE1pY3JvcxIkCg5zY3JvbGxfZGVsdGFfeBgIIAEoAVIMc2Nyb2xsRGVsdG'
    'FYEiQKDnNjcm9sbF9kZWx0YV95GAkgASgBUgxzY3JvbGxEZWx0YVk=');

@$core.Deprecated('Use keyEventDescriptor instead')
const KeyEvent$json = {
  '1': 'KeyEvent',
  '2': [
    {
      '1': 'kind',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.raccoon.v1.KeyKind',
      '10': 'kind'
    },
    {'1': 'physical', '3': 2, '4': 1, '5': 4, '10': 'physical'},
    {'1': 'logical', '3': 3, '4': 1, '5': 4, '10': 'logical'},
    {'1': 'character', '3': 4, '4': 1, '5': 9, '10': 'character'},
    {'1': 'timestamp_micros', '3': 5, '4': 1, '5': 4, '10': 'timestampMicros'},
    {'1': 'synthesized', '3': 6, '4': 1, '5': 8, '10': 'synthesized'},
  ],
};

/// Descriptor for `KeyEvent`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List keyEventDescriptor = $convert.base64Decode(
    'CghLZXlFdmVudBInCgRraW5kGAEgASgOMhMucmFjY29vbi52MS5LZXlLaW5kUgRraW5kEhoKCH'
    'BoeXNpY2FsGAIgASgEUghwaHlzaWNhbBIYCgdsb2dpY2FsGAMgASgEUgdsb2dpY2FsEhwKCWNo'
    'YXJhY3RlchgEIAEoCVIJY2hhcmFjdGVyEikKEHRpbWVzdGFtcF9taWNyb3MYBSABKARSD3RpbW'
    'VzdGFtcE1pY3JvcxIgCgtzeW50aGVzaXplZBgGIAEoCFILc3ludGhlc2l6ZWQ=');

@$core.Deprecated('Use shutdownDescriptor instead')
const Shutdown$json = {
  '1': 'Shutdown',
};

/// Descriptor for `Shutdown`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List shutdownDescriptor =
    $convert.base64Decode('CghTaHV0ZG93bg==');

@$core.Deprecated('Use platformResponseDescriptor instead')
const PlatformResponse$json = {
  '1': 'PlatformResponse',
  '2': [
    {'1': 'response_id', '3': 1, '4': 1, '5': 4, '10': 'responseId'},
    {'1': 'handled', '3': 2, '4': 1, '5': 8, '10': 'handled'},
    {'1': 'data', '3': 3, '4': 1, '5': 12, '10': 'data'},
  ],
};

/// Descriptor for `PlatformResponse`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List platformResponseDescriptor = $convert.base64Decode(
    'ChBQbGF0Zm9ybVJlc3BvbnNlEh8KC3Jlc3BvbnNlX2lkGAEgASgEUgpyZXNwb25zZUlkEhgKB2'
    'hhbmRsZWQYAiABKAhSB2hhbmRsZWQSEgoEZGF0YRgDIAEoDFIEZGF0YQ==');

@$core.Deprecated('Use clientMessageDescriptor instead')
const ClientMessage$json = {
  '1': 'ClientMessage',
  '2': [
    {
      '1': 'hello',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.raccoon.v1.ClientHello',
      '9': 0,
      '10': 'hello'
    },
    {
      '1': 'resize',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.raccoon.v1.Resize',
      '9': 0,
      '10': 'resize'
    },
    {
      '1': 'pointer',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.raccoon.v1.PointerEvent',
      '9': 0,
      '10': 'pointer'
    },
    {
      '1': 'key',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.raccoon.v1.KeyEvent',
      '9': 0,
      '10': 'key'
    },
    {
      '1': 'shutdown',
      '3': 5,
      '4': 1,
      '5': 11,
      '6': '.raccoon.v1.Shutdown',
      '9': 0,
      '10': 'shutdown'
    },
    {
      '1': 'platform_response',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.raccoon.v1.PlatformResponse',
      '9': 0,
      '10': 'platformResponse'
    },
    {
      '1': 'release_buffer',
      '3': 7,
      '4': 1,
      '5': 11,
      '6': '.raccoon.v1.ReleaseBuffer',
      '9': 0,
      '10': 'releaseBuffer'
    },
    {
      '1': 'text_editing',
      '3': 8,
      '4': 1,
      '5': 11,
      '6': '.raccoon.v1.TextEditing',
      '9': 0,
      '10': 'textEditing'
    },
  ],
  '8': [
    {'1': 'message'},
  ],
};

/// Descriptor for `ClientMessage`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List clientMessageDescriptor = $convert.base64Decode(
    'Cg1DbGllbnRNZXNzYWdlEi8KBWhlbGxvGAEgASgLMhcucmFjY29vbi52MS5DbGllbnRIZWxsb0'
    'gAUgVoZWxsbxIsCgZyZXNpemUYAiABKAsyEi5yYWNjb29uLnYxLlJlc2l6ZUgAUgZyZXNpemUS'
    'NAoHcG9pbnRlchgDIAEoCzIYLnJhY2Nvb24udjEuUG9pbnRlckV2ZW50SABSB3BvaW50ZXISKA'
    'oDa2V5GAQgASgLMhQucmFjY29vbi52MS5LZXlFdmVudEgAUgNrZXkSMgoIc2h1dGRvd24YBSAB'
    'KAsyFC5yYWNjb29uLnYxLlNodXRkb3duSABSCHNodXRkb3duEksKEXBsYXRmb3JtX3Jlc3Bvbn'
    'NlGAYgASgLMhwucmFjY29vbi52MS5QbGF0Zm9ybVJlc3BvbnNlSABSEHBsYXRmb3JtUmVzcG9u'
    'c2USQgoOcmVsZWFzZV9idWZmZXIYByABKAsyGS5yYWNjb29uLnYxLlJlbGVhc2VCdWZmZXJIAF'
    'INcmVsZWFzZUJ1ZmZlchI8Cgx0ZXh0X2VkaXRpbmcYCCABKAsyFy5yYWNjb29uLnYxLlRleHRF'
    'ZGl0aW5nSABSC3RleHRFZGl0aW5nQgkKB21lc3NhZ2U=');

@$core.Deprecated('Use textEditingDescriptor instead')
const TextEditing$json = {
  '1': 'TextEditing',
  '2': [
    {'1': 'text', '3': 1, '4': 1, '5': 9, '10': 'text'},
    {'1': 'selection_base', '3': 2, '4': 1, '5': 5, '10': 'selectionBase'},
    {'1': 'selection_extent', '3': 3, '4': 1, '5': 5, '10': 'selectionExtent'},
    {'1': 'composing_base', '3': 4, '4': 1, '5': 5, '10': 'composingBase'},
    {'1': 'composing_extent', '3': 5, '4': 1, '5': 5, '10': 'composingExtent'},
  ],
};

/// Descriptor for `TextEditing`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List textEditingDescriptor = $convert.base64Decode(
    'CgtUZXh0RWRpdGluZxISCgR0ZXh0GAEgASgJUgR0ZXh0EiUKDnNlbGVjdGlvbl9iYXNlGAIgAS'
    'gFUg1zZWxlY3Rpb25CYXNlEikKEHNlbGVjdGlvbl9leHRlbnQYAyABKAVSD3NlbGVjdGlvbkV4'
    'dGVudBIlCg5jb21wb3NpbmdfYmFzZRgEIAEoBVINY29tcG9zaW5nQmFzZRIpChBjb21wb3Npbm'
    'dfZXh0ZW50GAUgASgFUg9jb21wb3NpbmdFeHRlbnQ=');

@$core.Deprecated('Use runnerHelloDescriptor instead')
const RunnerHello$json = {
  '1': 'RunnerHello',
  '2': [
    {'1': 'protocol_version', '3': 1, '4': 1, '5': 13, '10': 'protocolVersion'},
    {'1': 'engine_revision', '3': 2, '4': 1, '5': 9, '10': 'engineRevision'},
    {'1': 'pid', '3': 3, '4': 1, '5': 13, '10': 'pid'},
  ],
};

/// Descriptor for `RunnerHello`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List runnerHelloDescriptor = $convert.base64Decode(
    'CgtSdW5uZXJIZWxsbxIpChBwcm90b2NvbF92ZXJzaW9uGAEgASgNUg9wcm90b2NvbFZlcnNpb2'
    '4SJwoPZW5naW5lX3JldmlzaW9uGAIgASgJUg5lbmdpbmVSZXZpc2lvbhIQCgNwaWQYAyABKA1S'
    'A3BpZA==');

@$core.Deprecated('Use frameDescriptor instead')
const Frame$json = {
  '1': 'Frame',
  '2': [
    {'1': 'sequence', '3': 1, '4': 1, '5': 4, '10': 'sequence'},
    {'1': 'width', '3': 2, '4': 1, '5': 13, '10': 'width'},
    {'1': 'height', '3': 3, '4': 1, '5': 13, '10': 'height'},
    {'1': 'row_bytes', '3': 4, '4': 1, '5': 13, '10': 'rowBytes'},
    {
      '1': 'format',
      '3': 5,
      '4': 1,
      '5': 14,
      '6': '.raccoon.v1.PixelFormat',
      '10': 'format'
    },
    {'1': 'pixels', '3': 6, '4': 1, '5': 12, '10': 'pixels'},
    {'1': 'timestamp_micros', '3': 7, '4': 1, '5': 4, '10': 'timestampMicros'},
    {'1': 'in_shared_buffer', '3': 8, '4': 1, '5': 8, '10': 'inSharedBuffer'},
    {'1': 'buffer_index', '3': 9, '4': 1, '5': 13, '10': 'bufferIndex'},
  ],
};

/// Descriptor for `Frame`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List frameDescriptor = $convert.base64Decode(
    'CgVGcmFtZRIaCghzZXF1ZW5jZRgBIAEoBFIIc2VxdWVuY2USFAoFd2lkdGgYAiABKA1SBXdpZH'
    'RoEhYKBmhlaWdodBgDIAEoDVIGaGVpZ2h0EhsKCXJvd19ieXRlcxgEIAEoDVIIcm93Qnl0ZXMS'
    'LwoGZm9ybWF0GAUgASgOMhcucmFjY29vbi52MS5QaXhlbEZvcm1hdFIGZm9ybWF0EhYKBnBpeG'
    'VscxgGIAEoDFIGcGl4ZWxzEikKEHRpbWVzdGFtcF9taWNyb3MYByABKARSD3RpbWVzdGFtcE1p'
    'Y3JvcxIoChBpbl9zaGFyZWRfYnVmZmVyGAggASgIUg5pblNoYXJlZEJ1ZmZlchIhCgxidWZmZX'
    'JfaW5kZXgYCSABKA1SC2J1ZmZlckluZGV4');

@$core.Deprecated('Use sharedBuffersDescriptor instead')
const SharedBuffers$json = {
  '1': 'SharedBuffers',
  '2': [
    {'1': 'count', '3': 1, '4': 1, '5': 13, '10': 'count'},
    {'1': 'size', '3': 2, '4': 1, '5': 4, '10': 'size'},
  ],
};

/// Descriptor for `SharedBuffers`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List sharedBuffersDescriptor = $convert.base64Decode(
    'Cg1TaGFyZWRCdWZmZXJzEhQKBWNvdW50GAEgASgNUgVjb3VudBISCgRzaXplGAIgASgEUgRzaX'
    'pl');

@$core.Deprecated('Use vmServiceDescriptor instead')
const VmService$json = {
  '1': 'VmService',
  '2': [
    {'1': 'uri', '3': 1, '4': 1, '5': 9, '10': 'uri'},
  ],
};

/// Descriptor for `VmService`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List vmServiceDescriptor =
    $convert.base64Decode('CglWbVNlcnZpY2USEAoDdXJpGAEgASgJUgN1cmk=');

@$core.Deprecated('Use logLineDescriptor instead')
const LogLine$json = {
  '1': 'LogLine',
  '2': [
    {'1': 'tag', '3': 1, '4': 1, '5': 9, '10': 'tag'},
    {'1': 'message', '3': 2, '4': 1, '5': 9, '10': 'message'},
  ],
};

/// Descriptor for `LogLine`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List logLineDescriptor = $convert.base64Decode(
    'CgdMb2dMaW5lEhAKA3RhZxgBIAEoCVIDdGFnEhgKB21lc3NhZ2UYAiABKAlSB21lc3NhZ2U=');

@$core.Deprecated('Use exitedDescriptor instead')
const Exited$json = {
  '1': 'Exited',
  '2': [
    {'1': 'code', '3': 1, '4': 1, '5': 5, '10': 'code'},
  ],
};

/// Descriptor for `Exited`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List exitedDescriptor =
    $convert.base64Decode('CgZFeGl0ZWQSEgoEY29kZRgBIAEoBVIEY29kZQ==');

@$core.Deprecated('Use platformMessageDescriptor instead')
const PlatformMessage$json = {
  '1': 'PlatformMessage',
  '2': [
    {'1': 'response_id', '3': 1, '4': 1, '5': 4, '10': 'responseId'},
    {'1': 'channel', '3': 2, '4': 1, '5': 9, '10': 'channel'},
    {'1': 'data', '3': 3, '4': 1, '5': 12, '10': 'data'},
  ],
};

/// Descriptor for `PlatformMessage`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List platformMessageDescriptor = $convert.base64Decode(
    'Cg9QbGF0Zm9ybU1lc3NhZ2USHwoLcmVzcG9uc2VfaWQYASABKARSCnJlc3BvbnNlSWQSGAoHY2'
    'hhbm5lbBgCIAEoCVIHY2hhbm5lbBISCgRkYXRhGAMgASgMUgRkYXRh');

@$core.Deprecated('Use textFieldDescriptor instead')
const TextField$json = {
  '1': 'TextField',
  '2': [
    {'1': 'active', '3': 1, '4': 1, '5': 8, '10': 'active'},
    {'1': 'text', '3': 2, '4': 1, '5': 9, '10': 'text'},
    {'1': 'selection_base', '3': 3, '4': 1, '5': 5, '10': 'selectionBase'},
    {'1': 'selection_extent', '3': 4, '4': 1, '5': 5, '10': 'selectionExtent'},
    {'1': 'composing_base', '3': 5, '4': 1, '5': 5, '10': 'composingBase'},
    {'1': 'composing_extent', '3': 6, '4': 1, '5': 5, '10': 'composingExtent'},
    {'1': 'multiline', '3': 7, '4': 1, '5': 8, '10': 'multiline'},
    {'1': 'input_action', '3': 8, '4': 1, '5': 9, '10': 'inputAction'},
    {'1': 'obscure', '3': 9, '4': 1, '5': 8, '10': 'obscure'},
  ],
};

/// Descriptor for `TextField`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List textFieldDescriptor = $convert.base64Decode(
    'CglUZXh0RmllbGQSFgoGYWN0aXZlGAEgASgIUgZhY3RpdmUSEgoEdGV4dBgCIAEoCVIEdGV4dB'
    'IlCg5zZWxlY3Rpb25fYmFzZRgDIAEoBVINc2VsZWN0aW9uQmFzZRIpChBzZWxlY3Rpb25fZXh0'
    'ZW50GAQgASgFUg9zZWxlY3Rpb25FeHRlbnQSJQoOY29tcG9zaW5nX2Jhc2UYBSABKAVSDWNvbX'
    'Bvc2luZ0Jhc2USKQoQY29tcG9zaW5nX2V4dGVudBgGIAEoBVIPY29tcG9zaW5nRXh0ZW50EhwK'
    'CW11bHRpbGluZRgHIAEoCFIJbXVsdGlsaW5lEiEKDGlucHV0X2FjdGlvbhgIIAEoCVILaW5wdX'
    'RBY3Rpb24SGAoHb2JzY3VyZRgJIAEoCFIHb2JzY3VyZQ==');

@$core.Deprecated('Use busyDescriptor instead')
const Busy$json = {
  '1': 'Busy',
  '2': [
    {'1': 'pid', '3': 1, '4': 1, '5': 13, '10': 'pid'},
  ],
};

/// Descriptor for `Busy`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List busyDescriptor =
    $convert.base64Decode('CgRCdXN5EhAKA3BpZBgBIAEoDVIDcGlk');

@$core.Deprecated('Use runnerMessageDescriptor instead')
const RunnerMessage$json = {
  '1': 'RunnerMessage',
  '2': [
    {
      '1': 'hello',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.raccoon.v1.RunnerHello',
      '9': 0,
      '10': 'hello'
    },
    {
      '1': 'frame',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.raccoon.v1.Frame',
      '9': 0,
      '10': 'frame'
    },
    {
      '1': 'vm_service',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.raccoon.v1.VmService',
      '9': 0,
      '10': 'vmService'
    },
    {
      '1': 'log',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.raccoon.v1.LogLine',
      '9': 0,
      '10': 'log'
    },
    {
      '1': 'exited',
      '3': 5,
      '4': 1,
      '5': 11,
      '6': '.raccoon.v1.Exited',
      '9': 0,
      '10': 'exited'
    },
    {
      '1': 'platform_message',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.raccoon.v1.PlatformMessage',
      '9': 0,
      '10': 'platformMessage'
    },
    {
      '1': 'shared_buffers',
      '3': 7,
      '4': 1,
      '5': 11,
      '6': '.raccoon.v1.SharedBuffers',
      '9': 0,
      '10': 'sharedBuffers'
    },
    {
      '1': 'busy',
      '3': 8,
      '4': 1,
      '5': 11,
      '6': '.raccoon.v1.Busy',
      '9': 0,
      '10': 'busy'
    },
    {
      '1': 'text_field',
      '3': 9,
      '4': 1,
      '5': 11,
      '6': '.raccoon.v1.TextField',
      '9': 0,
      '10': 'textField'
    },
  ],
  '8': [
    {'1': 'message'},
  ],
};

/// Descriptor for `RunnerMessage`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List runnerMessageDescriptor = $convert.base64Decode(
    'Cg1SdW5uZXJNZXNzYWdlEi8KBWhlbGxvGAEgASgLMhcucmFjY29vbi52MS5SdW5uZXJIZWxsb0'
    'gAUgVoZWxsbxIpCgVmcmFtZRgCIAEoCzIRLnJhY2Nvb24udjEuRnJhbWVIAFIFZnJhbWUSNgoK'
    'dm1fc2VydmljZRgDIAEoCzIVLnJhY2Nvb24udjEuVm1TZXJ2aWNlSABSCXZtU2VydmljZRInCg'
    'Nsb2cYBCABKAsyEy5yYWNjb29uLnYxLkxvZ0xpbmVIAFIDbG9nEiwKBmV4aXRlZBgFIAEoCzIS'
    'LnJhY2Nvb24udjEuRXhpdGVkSABSBmV4aXRlZBJIChBwbGF0Zm9ybV9tZXNzYWdlGAYgASgLMh'
    'sucmFjY29vbi52MS5QbGF0Zm9ybU1lc3NhZ2VIAFIPcGxhdGZvcm1NZXNzYWdlEkIKDnNoYXJl'
    'ZF9idWZmZXJzGAcgASgLMhkucmFjY29vbi52MS5TaGFyZWRCdWZmZXJzSABSDXNoYXJlZEJ1Zm'
    'ZlcnMSJgoEYnVzeRgIIAEoCzIQLnJhY2Nvb24udjEuQnVzeUgAUgRidXN5EjYKCnRleHRfZmll'
    'bGQYCSABKAsyFS5yYWNjb29uLnYxLlRleHRGaWVsZEgAUgl0ZXh0RmllbGRCCQoHbWVzc2FnZQ'
    '==');

// This is a generated file - do not edit.
//
// Generated from raccoon/v1/runner.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

class PointerPhase extends $pb.ProtobufEnum {
  static const PointerPhase POINTER_PHASE_UNSPECIFIED =
      PointerPhase._(0, _omitEnumNames ? '' : 'POINTER_PHASE_UNSPECIFIED');
  static const PointerPhase POINTER_PHASE_ADD =
      PointerPhase._(1, _omitEnumNames ? '' : 'POINTER_PHASE_ADD');
  static const PointerPhase POINTER_PHASE_REMOVE =
      PointerPhase._(2, _omitEnumNames ? '' : 'POINTER_PHASE_REMOVE');
  static const PointerPhase POINTER_PHASE_HOVER =
      PointerPhase._(3, _omitEnumNames ? '' : 'POINTER_PHASE_HOVER');
  static const PointerPhase POINTER_PHASE_DOWN =
      PointerPhase._(4, _omitEnumNames ? '' : 'POINTER_PHASE_DOWN');
  static const PointerPhase POINTER_PHASE_MOVE =
      PointerPhase._(5, _omitEnumNames ? '' : 'POINTER_PHASE_MOVE');
  static const PointerPhase POINTER_PHASE_UP =
      PointerPhase._(6, _omitEnumNames ? '' : 'POINTER_PHASE_UP');

  static const $core.List<PointerPhase> values = <PointerPhase>[
    POINTER_PHASE_UNSPECIFIED,
    POINTER_PHASE_ADD,
    POINTER_PHASE_REMOVE,
    POINTER_PHASE_HOVER,
    POINTER_PHASE_DOWN,
    POINTER_PHASE_MOVE,
    POINTER_PHASE_UP,
  ];

  static final $core.List<PointerPhase?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 6);
  static PointerPhase? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const PointerPhase._(super.value, super.name);
}

class PointerDevice extends $pb.ProtobufEnum {
  static const PointerDevice POINTER_DEVICE_UNSPECIFIED =
      PointerDevice._(0, _omitEnumNames ? '' : 'POINTER_DEVICE_UNSPECIFIED');
  static const PointerDevice POINTER_DEVICE_MOUSE =
      PointerDevice._(1, _omitEnumNames ? '' : 'POINTER_DEVICE_MOUSE');
  static const PointerDevice POINTER_DEVICE_TOUCH =
      PointerDevice._(2, _omitEnumNames ? '' : 'POINTER_DEVICE_TOUCH');

  static const $core.List<PointerDevice> values = <PointerDevice>[
    POINTER_DEVICE_UNSPECIFIED,
    POINTER_DEVICE_MOUSE,
    POINTER_DEVICE_TOUCH,
  ];

  static final $core.List<PointerDevice?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static PointerDevice? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const PointerDevice._(super.value, super.name);
}

class KeyKind extends $pb.ProtobufEnum {
  static const KeyKind KEY_KIND_UNSPECIFIED =
      KeyKind._(0, _omitEnumNames ? '' : 'KEY_KIND_UNSPECIFIED');
  static const KeyKind KEY_KIND_DOWN =
      KeyKind._(1, _omitEnumNames ? '' : 'KEY_KIND_DOWN');
  static const KeyKind KEY_KIND_UP =
      KeyKind._(2, _omitEnumNames ? '' : 'KEY_KIND_UP');
  static const KeyKind KEY_KIND_REPEAT =
      KeyKind._(3, _omitEnumNames ? '' : 'KEY_KIND_REPEAT');

  static const $core.List<KeyKind> values = <KeyKind>[
    KEY_KIND_UNSPECIFIED,
    KEY_KIND_DOWN,
    KEY_KIND_UP,
    KEY_KIND_REPEAT,
  ];

  static final $core.List<KeyKind?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 3);
  static KeyKind? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const KeyKind._(super.value, super.name);
}

class PixelFormat extends $pb.ProtobufEnum {
  static const PixelFormat PIXEL_FORMAT_UNSPECIFIED =
      PixelFormat._(0, _omitEnumNames ? '' : 'PIXEL_FORMAT_UNSPECIFIED');
  static const PixelFormat PIXEL_FORMAT_BGRA8888 =
      PixelFormat._(1, _omitEnumNames ? '' : 'PIXEL_FORMAT_BGRA8888');
  static const PixelFormat PIXEL_FORMAT_RGBA8888 =
      PixelFormat._(2, _omitEnumNames ? '' : 'PIXEL_FORMAT_RGBA8888');

  static const $core.List<PixelFormat> values = <PixelFormat>[
    PIXEL_FORMAT_UNSPECIFIED,
    PIXEL_FORMAT_BGRA8888,
    PIXEL_FORMAT_RGBA8888,
  ];

  static final $core.List<PixelFormat?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static PixelFormat? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const PixelFormat._(super.value, super.name);
}

class PluginState extends $pb.ProtobufEnum {
  static const PluginState PLUGIN_STATE_UNSPECIFIED =
      PluginState._(0, _omitEnumNames ? '' : 'PLUGIN_STATE_UNSPECIFIED');

  /// Loaded into the runner and registered: its channels are answered.
  static const PluginState PLUGIN_STATE_LOADED =
      PluginState._(1, _omitEnumNames ? '' : 'PLUGIN_STATE_LOADED');

  /// Did not build, or did not load; detail says.
  static const PluginState PLUGIN_STATE_FAILED =
      PluginState._(2, _omitEnumNames ? '' : 'PLUGIN_STATE_FAILED');

  /// Built and made no library: an FFI plugin without its toolchain.
  static const PluginState PLUGIN_STATE_BUILT_NOTHING =
      PluginState._(3, _omitEnumNames ? '' : 'PLUGIN_STATE_BUILT_NOTHING');

  /// Declares no implementation for this host: its calls will fail.
  static const PluginState PLUGIN_STATE_NO_HOST =
      PluginState._(4, _omitEnumNames ? '' : 'PLUGIN_STATE_NO_HOST');

  /// The runner answers its channels itself (the window plugins).
  static const PluginState PLUGIN_STATE_BUILT_IN =
      PluginState._(5, _omitEnumNames ? '' : 'PLUGIN_STATE_BUILT_IN');

  static const $core.List<PluginState> values = <PluginState>[
    PLUGIN_STATE_UNSPECIFIED,
    PLUGIN_STATE_LOADED,
    PLUGIN_STATE_FAILED,
    PLUGIN_STATE_BUILT_NOTHING,
    PLUGIN_STATE_NO_HOST,
    PLUGIN_STATE_BUILT_IN,
  ];

  static final $core.List<PluginState?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 5);
  static PluginState? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const PluginState._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');

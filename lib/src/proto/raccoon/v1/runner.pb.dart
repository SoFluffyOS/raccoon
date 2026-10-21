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

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

import 'runner.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'runner.pbenum.dart';

class ClientHello extends $pb.GeneratedMessage {
  factory ClientHello({
    $core.int? protocolVersion,
    $core.String? clientName,
    $core.bool? sharedBuffers,
    $core.int? pid,
    $core.bool? composes,
    $core.bool? gpuBuffers,
  }) {
    final result = ClientHello._();
    if (protocolVersion != null) result.protocolVersion = protocolVersion;
    if (clientName != null) result.clientName = clientName;
    if (sharedBuffers != null) result.sharedBuffers = sharedBuffers;
    if (pid != null) result.pid = pid;
    if (composes != null) result.composes = composes;
    if (gpuBuffers != null) result.gpuBuffers = gpuBuffers;
    return result;
  }

  ClientHello._();

  factory ClientHello.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ClientHello()..mergeFromBuffer(data, registry);
  factory ClientHello.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ClientHello()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ClientHello',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'raccoon.v1'),
      createEmptyInstance: ClientHello.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'protocolVersion',
        fieldType: $pb.PbFieldType.OU3)
    ..aOS(2, _omitFieldNames ? '' : 'clientName')
    ..aOB(3, _omitFieldNames ? '' : 'sharedBuffers')
    ..aI(4, _omitFieldNames ? '' : 'pid', fieldType: $pb.PbFieldType.OU3)
    ..aOB(5, _omitFieldNames ? '' : 'composes')
    ..aOB(6, _omitFieldNames ? '' : 'gpuBuffers')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClientHello clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClientHello copyWith(void Function(ClientHello) updates) =>
      super.copyWith((message) => updates(message as ClientHello))
          as ClientHello;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ClientHello() / ClientHello.new instead')
  static ClientHello create() => ClientHello._();
  static $pb.GeneratedMessage $_createMessage() => ClientHello._();
  @$core.override
  ClientHello createEmptyInstance() => ClientHello._();
  @$core.pragma('dart2js:noInline')
  static ClientHello getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ClientHello>(
          ClientHello.$_createMessage);
  static ClientHello? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get protocolVersion => $_getIZ(0);
  @$pb.TagNumber(1)
  set protocolVersion($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasProtocolVersion() => $_has(0);
  @$pb.TagNumber(1)
  void clearProtocolVersion() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get clientName => $_getSZ(1);
  @$pb.TagNumber(2)
  set clientName($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasClientName() => $_has(1);
  @$pb.TagNumber(2)
  void clearClientName() => $_clearField(2);

  /// The client can take frames from shared buffers whose file descriptors
  /// ride along the SharedBuffers message (Unix sockets only).
  @$pb.TagNumber(3)
  $core.bool get sharedBuffers => $_getBF(2);
  @$pb.TagNumber(3)
  set sharedBuffers($core.bool value) => $_setBool(2, value);
  @$pb.TagNumber(3)
  $core.bool hasSharedBuffers() => $_has(2);
  @$pb.TagNumber(3)
  void clearSharedBuffers() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.int get pid => $_getIZ(3);
  @$pb.TagNumber(4)
  set pid($core.int value) => $_setUnsignedInt32(3, value);
  @$pb.TagNumber(4)
  $core.bool hasPid() => $_has(3);
  @$pb.TagNumber(4)
  void clearPid() => $_clearField(4);

  /// The client has an input method and sends TextEditing for the active
  /// field; the runner then leaves typing characters to it. Keys still reach
  /// the app.
  @$pb.TagNumber(5)
  $core.bool get composes => $_getBF(4);
  @$pb.TagNumber(5)
  set composes($core.bool value) => $_setBool(4, value);
  @$pb.TagNumber(5)
  $core.bool hasComposes() => $_has(4);
  @$pb.TagNumber(5)
  void clearComposes() => $_clearField(5);

  /// The client can import GPU buffers (DRM dmabufs on Linux) and will take
  /// their file descriptors from the runner's GPU socket; frames then arrive
  /// as buffer indices, no pixels.
  @$pb.TagNumber(6)
  $core.bool get gpuBuffers => $_getBF(5);
  @$pb.TagNumber(6)
  set gpuBuffers($core.bool value) => $_setBool(5, value);
  @$pb.TagNumber(6)
  $core.bool hasGpuBuffers() => $_has(5);
  @$pb.TagNumber(6)
  void clearGpuBuffers() => $_clearField(6);
}

/// Gives a shared buffer back to the runner once its pixels were read.
class ReleaseBuffer extends $pb.GeneratedMessage {
  factory ReleaseBuffer({
    $core.int? index,
    $core.int? generation,
  }) {
    final result = ReleaseBuffer._();
    if (index != null) result.index = index;
    if (generation != null) result.generation = generation;
    return result;
  }

  ReleaseBuffer._();

  factory ReleaseBuffer.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ReleaseBuffer()..mergeFromBuffer(data, registry);
  factory ReleaseBuffer.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ReleaseBuffer()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ReleaseBuffer',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'raccoon.v1'),
      createEmptyInstance: ReleaseBuffer.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'index', fieldType: $pb.PbFieldType.OU3)
    ..aI(2, _omitFieldNames ? '' : 'generation', fieldType: $pb.PbFieldType.OU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReleaseBuffer clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ReleaseBuffer copyWith(void Function(ReleaseBuffer) updates) =>
      super.copyWith((message) => updates(message as ReleaseBuffer))
          as ReleaseBuffer;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ReleaseBuffer() / ReleaseBuffer.new instead')
  static ReleaseBuffer create() => ReleaseBuffer._();
  static $pb.GeneratedMessage $_createMessage() => ReleaseBuffer._();
  @$core.override
  ReleaseBuffer createEmptyInstance() => ReleaseBuffer._();
  @$core.pragma('dart2js:noInline')
  static ReleaseBuffer getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ReleaseBuffer>(
          ReleaseBuffer.$_createMessage);
  static ReleaseBuffer? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get index => $_getIZ(0);
  @$pb.TagNumber(1)
  set index($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasIndex() => $_has(0);
  @$pb.TagNumber(1)
  void clearIndex() => $_clearField(1);

  /// Which GPU buffer set the index belongs to; 0 for shared buffers.
  @$pb.TagNumber(2)
  $core.int get generation => $_getIZ(1);
  @$pb.TagNumber(2)
  set generation($core.int value) => $_setUnsignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasGeneration() => $_has(1);
  @$pb.TagNumber(2)
  void clearGeneration() => $_clearField(2);
}

class Resize extends $pb.GeneratedMessage {
  factory Resize({
    $core.int? width,
    $core.int? height,
    $core.double? pixelRatio,
  }) {
    final result = Resize._();
    if (width != null) result.width = width;
    if (height != null) result.height = height;
    if (pixelRatio != null) result.pixelRatio = pixelRatio;
    return result;
  }

  Resize._();

  factory Resize.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Resize()..mergeFromBuffer(data, registry);
  factory Resize.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Resize()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Resize',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'raccoon.v1'),
      createEmptyInstance: Resize.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'width', fieldType: $pb.PbFieldType.OU3)
    ..aI(2, _omitFieldNames ? '' : 'height', fieldType: $pb.PbFieldType.OU3)
    ..aD(3, _omitFieldNames ? '' : 'pixelRatio')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Resize clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Resize copyWith(void Function(Resize) updates) =>
      super.copyWith((message) => updates(message as Resize)) as Resize;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Resize() / Resize.new instead')
  static Resize create() => Resize._();
  static $pb.GeneratedMessage $_createMessage() => Resize._();
  @$core.override
  Resize createEmptyInstance() => Resize._();
  @$core.pragma('dart2js:noInline')
  static Resize getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Resize>(Resize.$_createMessage);
  static Resize? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get width => $_getIZ(0);
  @$pb.TagNumber(1)
  set width($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasWidth() => $_has(0);
  @$pb.TagNumber(1)
  void clearWidth() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.int get height => $_getIZ(1);
  @$pb.TagNumber(2)
  set height($core.int value) => $_setUnsignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasHeight() => $_has(1);
  @$pb.TagNumber(2)
  void clearHeight() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.double get pixelRatio => $_getN(2);
  @$pb.TagNumber(3)
  set pixelRatio($core.double value) => $_setDouble(2, value);
  @$pb.TagNumber(3)
  $core.bool hasPixelRatio() => $_has(2);
  @$pb.TagNumber(3)
  void clearPixelRatio() => $_clearField(3);
}

class PointerEvent extends $pb.GeneratedMessage {
  factory PointerEvent({
    PointerPhase? phase,
    $core.double? x,
    $core.double? y,
    $fixnum.Int64? buttons,
    PointerDevice? device,
    $core.int? pointerId,
    $fixnum.Int64? timestampMicros,
    $core.double? scrollDeltaX,
    $core.double? scrollDeltaY,
  }) {
    final result = PointerEvent._();
    if (phase != null) result.phase = phase;
    if (x != null) result.x = x;
    if (y != null) result.y = y;
    if (buttons != null) result.buttons = buttons;
    if (device != null) result.device = device;
    if (pointerId != null) result.pointerId = pointerId;
    if (timestampMicros != null) result.timestampMicros = timestampMicros;
    if (scrollDeltaX != null) result.scrollDeltaX = scrollDeltaX;
    if (scrollDeltaY != null) result.scrollDeltaY = scrollDeltaY;
    return result;
  }

  PointerEvent._();

  factory PointerEvent.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      PointerEvent()..mergeFromBuffer(data, registry);
  factory PointerEvent.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      PointerEvent()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PointerEvent',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'raccoon.v1'),
      createEmptyInstance: PointerEvent.$_createMessage)
    ..aE<PointerPhase>(1, _omitFieldNames ? '' : 'phase',
        enumValues: PointerPhase.values)
    ..aD(2, _omitFieldNames ? '' : 'x')
    ..aD(3, _omitFieldNames ? '' : 'y')
    ..aInt64(4, _omitFieldNames ? '' : 'buttons')
    ..aE<PointerDevice>(5, _omitFieldNames ? '' : 'device',
        enumValues: PointerDevice.values)
    ..aI(6, _omitFieldNames ? '' : 'pointerId')
    ..a<$fixnum.Int64>(
        7, _omitFieldNames ? '' : 'timestampMicros', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aD(8, _omitFieldNames ? '' : 'scrollDeltaX')
    ..aD(9, _omitFieldNames ? '' : 'scrollDeltaY')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PointerEvent clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PointerEvent copyWith(void Function(PointerEvent) updates) =>
      super.copyWith((message) => updates(message as PointerEvent))
          as PointerEvent;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use PointerEvent() / PointerEvent.new instead')
  static PointerEvent create() => PointerEvent._();
  static $pb.GeneratedMessage $_createMessage() => PointerEvent._();
  @$core.override
  PointerEvent createEmptyInstance() => PointerEvent._();
  @$core.pragma('dart2js:noInline')
  static PointerEvent getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<PointerEvent>(
          PointerEvent.$_createMessage);
  static PointerEvent? _defaultInstance;

  @$pb.TagNumber(1)
  PointerPhase get phase => $_getN(0);
  @$pb.TagNumber(1)
  set phase(PointerPhase value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasPhase() => $_has(0);
  @$pb.TagNumber(1)
  void clearPhase() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.double get x => $_getN(1);
  @$pb.TagNumber(2)
  set x($core.double value) => $_setDouble(1, value);
  @$pb.TagNumber(2)
  $core.bool hasX() => $_has(1);
  @$pb.TagNumber(2)
  void clearX() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.double get y => $_getN(2);
  @$pb.TagNumber(3)
  set y($core.double value) => $_setDouble(2, value);
  @$pb.TagNumber(3)
  $core.bool hasY() => $_has(2);
  @$pb.TagNumber(3)
  void clearY() => $_clearField(3);

  /// Bit set of pressed buttons; bit 0 is the primary button.
  @$pb.TagNumber(4)
  $fixnum.Int64 get buttons => $_getI64(3);
  @$pb.TagNumber(4)
  set buttons($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasButtons() => $_has(3);
  @$pb.TagNumber(4)
  void clearButtons() => $_clearField(4);

  @$pb.TagNumber(5)
  PointerDevice get device => $_getN(4);
  @$pb.TagNumber(5)
  set device(PointerDevice value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasDevice() => $_has(4);
  @$pb.TagNumber(5)
  void clearDevice() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.int get pointerId => $_getIZ(5);
  @$pb.TagNumber(6)
  set pointerId($core.int value) => $_setSignedInt32(5, value);
  @$pb.TagNumber(6)
  $core.bool hasPointerId() => $_has(5);
  @$pb.TagNumber(6)
  void clearPointerId() => $_clearField(6);

  @$pb.TagNumber(7)
  $fixnum.Int64 get timestampMicros => $_getI64(6);
  @$pb.TagNumber(7)
  set timestampMicros($fixnum.Int64 value) => $_setInt64(6, value);
  @$pb.TagNumber(7)
  $core.bool hasTimestampMicros() => $_has(6);
  @$pb.TagNumber(7)
  void clearTimestampMicros() => $_clearField(7);

  @$pb.TagNumber(8)
  $core.double get scrollDeltaX => $_getN(7);
  @$pb.TagNumber(8)
  set scrollDeltaX($core.double value) => $_setDouble(7, value);
  @$pb.TagNumber(8)
  $core.bool hasScrollDeltaX() => $_has(7);
  @$pb.TagNumber(8)
  void clearScrollDeltaX() => $_clearField(8);

  @$pb.TagNumber(9)
  $core.double get scrollDeltaY => $_getN(8);
  @$pb.TagNumber(9)
  set scrollDeltaY($core.double value) => $_setDouble(8, value);
  @$pb.TagNumber(9)
  $core.bool hasScrollDeltaY() => $_has(8);
  @$pb.TagNumber(9)
  void clearScrollDeltaY() => $_clearField(9);
}

class KeyEvent extends $pb.GeneratedMessage {
  factory KeyEvent({
    KeyKind? kind,
    $fixnum.Int64? physical,
    $fixnum.Int64? logical,
    $core.String? character,
    $fixnum.Int64? timestampMicros,
    $core.bool? synthesized,
  }) {
    final result = KeyEvent._();
    if (kind != null) result.kind = kind;
    if (physical != null) result.physical = physical;
    if (logical != null) result.logical = logical;
    if (character != null) result.character = character;
    if (timestampMicros != null) result.timestampMicros = timestampMicros;
    if (synthesized != null) result.synthesized = synthesized;
    return result;
  }

  KeyEvent._();

  factory KeyEvent.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      KeyEvent()..mergeFromBuffer(data, registry);
  factory KeyEvent.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      KeyEvent()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'KeyEvent',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'raccoon.v1'),
      createEmptyInstance: KeyEvent.$_createMessage)
    ..aE<KeyKind>(1, _omitFieldNames ? '' : 'kind', enumValues: KeyKind.values)
    ..a<$fixnum.Int64>(
        2, _omitFieldNames ? '' : 'physical', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(3, _omitFieldNames ? '' : 'logical', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aOS(4, _omitFieldNames ? '' : 'character')
    ..a<$fixnum.Int64>(
        5, _omitFieldNames ? '' : 'timestampMicros', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aOB(6, _omitFieldNames ? '' : 'synthesized')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  KeyEvent clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  KeyEvent copyWith(void Function(KeyEvent) updates) =>
      super.copyWith((message) => updates(message as KeyEvent)) as KeyEvent;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use KeyEvent() / KeyEvent.new instead')
  static KeyEvent create() => KeyEvent._();
  static $pb.GeneratedMessage $_createMessage() => KeyEvent._();
  @$core.override
  KeyEvent createEmptyInstance() => KeyEvent._();
  @$core.pragma('dart2js:noInline')
  static KeyEvent getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<KeyEvent>(KeyEvent.$_createMessage);
  static KeyEvent? _defaultInstance;

  @$pb.TagNumber(1)
  KeyKind get kind => $_getN(0);
  @$pb.TagNumber(1)
  set kind(KeyKind value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasKind() => $_has(0);
  @$pb.TagNumber(1)
  void clearKind() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get physical => $_getI64(1);
  @$pb.TagNumber(2)
  set physical($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasPhysical() => $_has(1);
  @$pb.TagNumber(2)
  void clearPhysical() => $_clearField(2);

  @$pb.TagNumber(3)
  $fixnum.Int64 get logical => $_getI64(2);
  @$pb.TagNumber(3)
  set logical($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasLogical() => $_has(2);
  @$pb.TagNumber(3)
  void clearLogical() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get character => $_getSZ(3);
  @$pb.TagNumber(4)
  set character($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasCharacter() => $_has(3);
  @$pb.TagNumber(4)
  void clearCharacter() => $_clearField(4);

  @$pb.TagNumber(5)
  $fixnum.Int64 get timestampMicros => $_getI64(4);
  @$pb.TagNumber(5)
  set timestampMicros($fixnum.Int64 value) => $_setInt64(4, value);
  @$pb.TagNumber(5)
  $core.bool hasTimestampMicros() => $_has(4);
  @$pb.TagNumber(5)
  void clearTimestampMicros() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.bool get synthesized => $_getBF(5);
  @$pb.TagNumber(6)
  set synthesized($core.bool value) => $_setBool(5, value);
  @$pb.TagNumber(6)
  $core.bool hasSynthesized() => $_has(5);
  @$pb.TagNumber(6)
  void clearSynthesized() => $_clearField(6);
}

class Shutdown extends $pb.GeneratedMessage {
  factory Shutdown() => Shutdown._();

  Shutdown._();

  factory Shutdown.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Shutdown()..mergeFromBuffer(data, registry);
  factory Shutdown.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Shutdown()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Shutdown',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'raccoon.v1'),
      createEmptyInstance: Shutdown.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Shutdown clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Shutdown copyWith(void Function(Shutdown) updates) =>
      super.copyWith((message) => updates(message as Shutdown)) as Shutdown;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Shutdown() / Shutdown.new instead')
  static Shutdown create() => Shutdown._();
  static $pb.GeneratedMessage $_createMessage() => Shutdown._();
  @$core.override
  Shutdown createEmptyInstance() => Shutdown._();
  @$core.pragma('dart2js:noInline')
  static Shutdown getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Shutdown>(Shutdown.$_createMessage);
  static Shutdown? _defaultInstance;
}

/// Answers a PlatformMessage. handled=false means "no plugin": the app sees
/// a null reply, as it would on a desktop without that plugin.
class PlatformResponse extends $pb.GeneratedMessage {
  factory PlatformResponse({
    $fixnum.Int64? responseId,
    $core.bool? handled,
    $core.List<$core.int>? data,
  }) {
    final result = PlatformResponse._();
    if (responseId != null) result.responseId = responseId;
    if (handled != null) result.handled = handled;
    if (data != null) result.data = data;
    return result;
  }

  PlatformResponse._();

  factory PlatformResponse.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      PlatformResponse()..mergeFromBuffer(data, registry);
  factory PlatformResponse.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      PlatformResponse()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PlatformResponse',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'raccoon.v1'),
      createEmptyInstance: PlatformResponse.$_createMessage)
    ..a<$fixnum.Int64>(
        1, _omitFieldNames ? '' : 'responseId', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aOB(2, _omitFieldNames ? '' : 'handled')
    ..a<$core.List<$core.int>>(
        3, _omitFieldNames ? '' : 'data', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PlatformResponse clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PlatformResponse copyWith(void Function(PlatformResponse) updates) =>
      super.copyWith((message) => updates(message as PlatformResponse))
          as PlatformResponse;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use PlatformResponse() / PlatformResponse.new instead')
  static PlatformResponse create() => PlatformResponse._();
  static $pb.GeneratedMessage $_createMessage() => PlatformResponse._();
  @$core.override
  PlatformResponse createEmptyInstance() => PlatformResponse._();
  @$core.pragma('dart2js:noInline')
  static PlatformResponse getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<PlatformResponse>(
          PlatformResponse.$_createMessage);
  static PlatformResponse? _defaultInstance;

  @$pb.TagNumber(1)
  $fixnum.Int64 get responseId => $_getI64(0);
  @$pb.TagNumber(1)
  set responseId($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasResponseId() => $_has(0);
  @$pb.TagNumber(1)
  void clearResponseId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.bool get handled => $_getBF(1);
  @$pb.TagNumber(2)
  set handled($core.bool value) => $_setBool(1, value);
  @$pb.TagNumber(2)
  $core.bool hasHandled() => $_has(1);
  @$pb.TagNumber(2)
  void clearHandled() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.List<$core.int> get data => $_getN(2);
  @$pb.TagNumber(3)
  set data($core.List<$core.int> value) => $_setBytes(2, value);
  @$pb.TagNumber(3)
  $core.bool hasData() => $_has(2);
  @$pb.TagNumber(3)
  void clearData() => $_clearField(3);
}

enum ClientMessage_Message {
  hello,
  resize,
  pointer,
  key,
  shutdown,
  platformResponse,
  releaseBuffer,
  textEditing,
  notSet
}

class ClientMessage extends $pb.GeneratedMessage {
  factory ClientMessage({
    ClientHello? hello,
    Resize? resize,
    PointerEvent? pointer,
    KeyEvent? key,
    Shutdown? shutdown,
    PlatformResponse? platformResponse,
    ReleaseBuffer? releaseBuffer,
    TextEditing? textEditing,
  }) {
    final result = ClientMessage._();
    if (hello != null) result.hello = hello;
    if (resize != null) result.resize = resize;
    if (pointer != null) result.pointer = pointer;
    if (key != null) result.key = key;
    if (shutdown != null) result.shutdown = shutdown;
    if (platformResponse != null) result.platformResponse = platformResponse;
    if (releaseBuffer != null) result.releaseBuffer = releaseBuffer;
    if (textEditing != null) result.textEditing = textEditing;
    return result;
  }

  ClientMessage._();

  factory ClientMessage.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ClientMessage()..mergeFromBuffer(data, registry);
  factory ClientMessage.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ClientMessage()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, ClientMessage_Message>
      _ClientMessage_MessageByTag = {
    1: ClientMessage_Message.hello,
    2: ClientMessage_Message.resize,
    3: ClientMessage_Message.pointer,
    4: ClientMessage_Message.key,
    5: ClientMessage_Message.shutdown,
    6: ClientMessage_Message.platformResponse,
    7: ClientMessage_Message.releaseBuffer,
    8: ClientMessage_Message.textEditing,
    0: ClientMessage_Message.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ClientMessage',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'raccoon.v1'),
      createEmptyInstance: ClientMessage.$_createMessage)
    ..oo(0, [1, 2, 3, 4, 5, 6, 7, 8])
    ..aOM<ClientHello>(1, _omitFieldNames ? '' : 'hello',
        subBuilder: ClientHello.$_createMessage)
    ..aOM<Resize>(2, _omitFieldNames ? '' : 'resize',
        subBuilder: Resize.$_createMessage)
    ..aOM<PointerEvent>(3, _omitFieldNames ? '' : 'pointer',
        subBuilder: PointerEvent.$_createMessage)
    ..aOM<KeyEvent>(4, _omitFieldNames ? '' : 'key',
        subBuilder: KeyEvent.$_createMessage)
    ..aOM<Shutdown>(5, _omitFieldNames ? '' : 'shutdown',
        subBuilder: Shutdown.$_createMessage)
    ..aOM<PlatformResponse>(6, _omitFieldNames ? '' : 'platformResponse',
        subBuilder: PlatformResponse.$_createMessage)
    ..aOM<ReleaseBuffer>(7, _omitFieldNames ? '' : 'releaseBuffer',
        subBuilder: ReleaseBuffer.$_createMessage)
    ..aOM<TextEditing>(8, _omitFieldNames ? '' : 'textEditing',
        subBuilder: TextEditing.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClientMessage clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClientMessage copyWith(void Function(ClientMessage) updates) =>
      super.copyWith((message) => updates(message as ClientMessage))
          as ClientMessage;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ClientMessage() / ClientMessage.new instead')
  static ClientMessage create() => ClientMessage._();
  static $pb.GeneratedMessage $_createMessage() => ClientMessage._();
  @$core.override
  ClientMessage createEmptyInstance() => ClientMessage._();
  @$core.pragma('dart2js:noInline')
  static ClientMessage getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ClientMessage>(
          ClientMessage.$_createMessage);
  static ClientMessage? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  @$pb.TagNumber(8)
  ClientMessage_Message whichMessage() =>
      _ClientMessage_MessageByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  @$pb.TagNumber(8)
  void clearMessage() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  ClientHello get hello => $_getN(0);
  @$pb.TagNumber(1)
  set hello(ClientHello value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasHello() => $_has(0);
  @$pb.TagNumber(1)
  void clearHello() => $_clearField(1);
  @$pb.TagNumber(1)
  ClientHello ensureHello() => $_ensure(0);

  @$pb.TagNumber(2)
  Resize get resize => $_getN(1);
  @$pb.TagNumber(2)
  set resize(Resize value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasResize() => $_has(1);
  @$pb.TagNumber(2)
  void clearResize() => $_clearField(2);
  @$pb.TagNumber(2)
  Resize ensureResize() => $_ensure(1);

  @$pb.TagNumber(3)
  PointerEvent get pointer => $_getN(2);
  @$pb.TagNumber(3)
  set pointer(PointerEvent value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasPointer() => $_has(2);
  @$pb.TagNumber(3)
  void clearPointer() => $_clearField(3);
  @$pb.TagNumber(3)
  PointerEvent ensurePointer() => $_ensure(2);

  @$pb.TagNumber(4)
  KeyEvent get key => $_getN(3);
  @$pb.TagNumber(4)
  set key(KeyEvent value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasKey() => $_has(3);
  @$pb.TagNumber(4)
  void clearKey() => $_clearField(4);
  @$pb.TagNumber(4)
  KeyEvent ensureKey() => $_ensure(3);

  @$pb.TagNumber(5)
  Shutdown get shutdown => $_getN(4);
  @$pb.TagNumber(5)
  set shutdown(Shutdown value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasShutdown() => $_has(4);
  @$pb.TagNumber(5)
  void clearShutdown() => $_clearField(5);
  @$pb.TagNumber(5)
  Shutdown ensureShutdown() => $_ensure(4);

  @$pb.TagNumber(6)
  PlatformResponse get platformResponse => $_getN(5);
  @$pb.TagNumber(6)
  set platformResponse(PlatformResponse value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasPlatformResponse() => $_has(5);
  @$pb.TagNumber(6)
  void clearPlatformResponse() => $_clearField(6);
  @$pb.TagNumber(6)
  PlatformResponse ensurePlatformResponse() => $_ensure(5);

  @$pb.TagNumber(7)
  ReleaseBuffer get releaseBuffer => $_getN(6);
  @$pb.TagNumber(7)
  set releaseBuffer(ReleaseBuffer value) => $_setField(7, value);
  @$pb.TagNumber(7)
  $core.bool hasReleaseBuffer() => $_has(6);
  @$pb.TagNumber(7)
  void clearReleaseBuffer() => $_clearField(7);
  @$pb.TagNumber(7)
  ReleaseBuffer ensureReleaseBuffer() => $_ensure(6);

  @$pb.TagNumber(8)
  TextEditing get textEditing => $_getN(7);
  @$pb.TagNumber(8)
  set textEditing(TextEditing value) => $_setField(8, value);
  @$pb.TagNumber(8)
  $core.bool hasTextEditing() => $_has(7);
  @$pb.TagNumber(8)
  void clearTextEditing() => $_clearField(8);
  @$pb.TagNumber(8)
  TextEditing ensureTextEditing() => $_ensure(7);
}

/// The client's input method produced a value for the active text field:
/// the whole value, as Flutter's TextEditingValue, offsets in UTF-16 code
/// units; -1,-1 for no composing range.
class TextEditing extends $pb.GeneratedMessage {
  factory TextEditing({
    $core.String? text,
    $core.int? selectionBase,
    $core.int? selectionExtent,
    $core.int? composingBase,
    $core.int? composingExtent,
  }) {
    final result = TextEditing._();
    if (text != null) result.text = text;
    if (selectionBase != null) result.selectionBase = selectionBase;
    if (selectionExtent != null) result.selectionExtent = selectionExtent;
    if (composingBase != null) result.composingBase = composingBase;
    if (composingExtent != null) result.composingExtent = composingExtent;
    return result;
  }

  TextEditing._();

  factory TextEditing.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      TextEditing()..mergeFromBuffer(data, registry);
  factory TextEditing.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      TextEditing()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TextEditing',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'raccoon.v1'),
      createEmptyInstance: TextEditing.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'text')
    ..aI(2, _omitFieldNames ? '' : 'selectionBase')
    ..aI(3, _omitFieldNames ? '' : 'selectionExtent')
    ..aI(4, _omitFieldNames ? '' : 'composingBase')
    ..aI(5, _omitFieldNames ? '' : 'composingExtent')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TextEditing clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TextEditing copyWith(void Function(TextEditing) updates) =>
      super.copyWith((message) => updates(message as TextEditing))
          as TextEditing;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use TextEditing() / TextEditing.new instead')
  static TextEditing create() => TextEditing._();
  static $pb.GeneratedMessage $_createMessage() => TextEditing._();
  @$core.override
  TextEditing createEmptyInstance() => TextEditing._();
  @$core.pragma('dart2js:noInline')
  static TextEditing getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<TextEditing>(
          TextEditing.$_createMessage);
  static TextEditing? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get text => $_getSZ(0);
  @$pb.TagNumber(1)
  set text($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasText() => $_has(0);
  @$pb.TagNumber(1)
  void clearText() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.int get selectionBase => $_getIZ(1);
  @$pb.TagNumber(2)
  set selectionBase($core.int value) => $_setSignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasSelectionBase() => $_has(1);
  @$pb.TagNumber(2)
  void clearSelectionBase() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.int get selectionExtent => $_getIZ(2);
  @$pb.TagNumber(3)
  set selectionExtent($core.int value) => $_setSignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasSelectionExtent() => $_has(2);
  @$pb.TagNumber(3)
  void clearSelectionExtent() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.int get composingBase => $_getIZ(3);
  @$pb.TagNumber(4)
  set composingBase($core.int value) => $_setSignedInt32(3, value);
  @$pb.TagNumber(4)
  $core.bool hasComposingBase() => $_has(3);
  @$pb.TagNumber(4)
  void clearComposingBase() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.int get composingExtent => $_getIZ(4);
  @$pb.TagNumber(5)
  set composingExtent($core.int value) => $_setSignedInt32(4, value);
  @$pb.TagNumber(5)
  $core.bool hasComposingExtent() => $_has(4);
  @$pb.TagNumber(5)
  void clearComposingExtent() => $_clearField(5);
}

class RunnerHello extends $pb.GeneratedMessage {
  factory RunnerHello({
    $core.int? protocolVersion,
    $core.String? engineRevision,
    $core.int? pid,
  }) {
    final result = RunnerHello._();
    if (protocolVersion != null) result.protocolVersion = protocolVersion;
    if (engineRevision != null) result.engineRevision = engineRevision;
    if (pid != null) result.pid = pid;
    return result;
  }

  RunnerHello._();

  factory RunnerHello.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RunnerHello()..mergeFromBuffer(data, registry);
  factory RunnerHello.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RunnerHello()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RunnerHello',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'raccoon.v1'),
      createEmptyInstance: RunnerHello.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'protocolVersion',
        fieldType: $pb.PbFieldType.OU3)
    ..aOS(2, _omitFieldNames ? '' : 'engineRevision')
    ..aI(3, _omitFieldNames ? '' : 'pid', fieldType: $pb.PbFieldType.OU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RunnerHello clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RunnerHello copyWith(void Function(RunnerHello) updates) =>
      super.copyWith((message) => updates(message as RunnerHello))
          as RunnerHello;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use RunnerHello() / RunnerHello.new instead')
  static RunnerHello create() => RunnerHello._();
  static $pb.GeneratedMessage $_createMessage() => RunnerHello._();
  @$core.override
  RunnerHello createEmptyInstance() => RunnerHello._();
  @$core.pragma('dart2js:noInline')
  static RunnerHello getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<RunnerHello>(
          RunnerHello.$_createMessage);
  static RunnerHello? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get protocolVersion => $_getIZ(0);
  @$pb.TagNumber(1)
  set protocolVersion($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasProtocolVersion() => $_has(0);
  @$pb.TagNumber(1)
  void clearProtocolVersion() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get engineRevision => $_getSZ(1);
  @$pb.TagNumber(2)
  set engineRevision($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasEngineRevision() => $_has(1);
  @$pb.TagNumber(2)
  void clearEngineRevision() => $_clearField(2);

  /// The runner's process id, so the client can watch its memory.
  @$pb.TagNumber(3)
  $core.int get pid => $_getIZ(2);
  @$pb.TagNumber(3)
  set pid($core.int value) => $_setUnsignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasPid() => $_has(2);
  @$pb.TagNumber(3)
  void clearPid() => $_clearField(3);
}

/// A frame carries its pixels inline, or names the shared buffer that holds
/// them; then pixels is empty and the client releases the buffer when done.
class Frame extends $pb.GeneratedMessage {
  factory Frame({
    $fixnum.Int64? sequence,
    $core.int? width,
    $core.int? height,
    $core.int? rowBytes,
    PixelFormat? format,
    $core.List<$core.int>? pixels,
    $fixnum.Int64? timestampMicros,
    $core.bool? inSharedBuffer,
    $core.int? bufferIndex,
    $core.bool? inGpuBuffer,
    $core.int? gpuGeneration,
  }) {
    final result = Frame._();
    if (sequence != null) result.sequence = sequence;
    if (width != null) result.width = width;
    if (height != null) result.height = height;
    if (rowBytes != null) result.rowBytes = rowBytes;
    if (format != null) result.format = format;
    if (pixels != null) result.pixels = pixels;
    if (timestampMicros != null) result.timestampMicros = timestampMicros;
    if (inSharedBuffer != null) result.inSharedBuffer = inSharedBuffer;
    if (bufferIndex != null) result.bufferIndex = bufferIndex;
    if (inGpuBuffer != null) result.inGpuBuffer = inGpuBuffer;
    if (gpuGeneration != null) result.gpuGeneration = gpuGeneration;
    return result;
  }

  Frame._();

  factory Frame.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Frame()..mergeFromBuffer(data, registry);
  factory Frame.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Frame()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Frame',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'raccoon.v1'),
      createEmptyInstance: Frame.$_createMessage)
    ..a<$fixnum.Int64>(
        1, _omitFieldNames ? '' : 'sequence', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aI(2, _omitFieldNames ? '' : 'width', fieldType: $pb.PbFieldType.OU3)
    ..aI(3, _omitFieldNames ? '' : 'height', fieldType: $pb.PbFieldType.OU3)
    ..aI(4, _omitFieldNames ? '' : 'rowBytes', fieldType: $pb.PbFieldType.OU3)
    ..aE<PixelFormat>(5, _omitFieldNames ? '' : 'format',
        enumValues: PixelFormat.values)
    ..a<$core.List<$core.int>>(
        6, _omitFieldNames ? '' : 'pixels', $pb.PbFieldType.OY)
    ..a<$fixnum.Int64>(
        7, _omitFieldNames ? '' : 'timestampMicros', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aOB(8, _omitFieldNames ? '' : 'inSharedBuffer')
    ..aI(9, _omitFieldNames ? '' : 'bufferIndex',
        fieldType: $pb.PbFieldType.OU3)
    ..aOB(10, _omitFieldNames ? '' : 'inGpuBuffer')
    ..aI(11, _omitFieldNames ? '' : 'gpuGeneration',
        fieldType: $pb.PbFieldType.OU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Frame clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Frame copyWith(void Function(Frame) updates) =>
      super.copyWith((message) => updates(message as Frame)) as Frame;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Frame() / Frame.new instead')
  static Frame create() => Frame._();
  static $pb.GeneratedMessage $_createMessage() => Frame._();
  @$core.override
  Frame createEmptyInstance() => Frame._();
  @$core.pragma('dart2js:noInline')
  static Frame getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Frame>(Frame.$_createMessage);
  static Frame? _defaultInstance;

  @$pb.TagNumber(1)
  $fixnum.Int64 get sequence => $_getI64(0);
  @$pb.TagNumber(1)
  set sequence($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasSequence() => $_has(0);
  @$pb.TagNumber(1)
  void clearSequence() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.int get width => $_getIZ(1);
  @$pb.TagNumber(2)
  set width($core.int value) => $_setUnsignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasWidth() => $_has(1);
  @$pb.TagNumber(2)
  void clearWidth() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.int get height => $_getIZ(2);
  @$pb.TagNumber(3)
  set height($core.int value) => $_setUnsignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasHeight() => $_has(2);
  @$pb.TagNumber(3)
  void clearHeight() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.int get rowBytes => $_getIZ(3);
  @$pb.TagNumber(4)
  set rowBytes($core.int value) => $_setUnsignedInt32(3, value);
  @$pb.TagNumber(4)
  $core.bool hasRowBytes() => $_has(3);
  @$pb.TagNumber(4)
  void clearRowBytes() => $_clearField(4);

  @$pb.TagNumber(5)
  PixelFormat get format => $_getN(4);
  @$pb.TagNumber(5)
  set format(PixelFormat value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasFormat() => $_has(4);
  @$pb.TagNumber(5)
  void clearFormat() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.List<$core.int> get pixels => $_getN(5);
  @$pb.TagNumber(6)
  set pixels($core.List<$core.int> value) => $_setBytes(5, value);
  @$pb.TagNumber(6)
  $core.bool hasPixels() => $_has(5);
  @$pb.TagNumber(6)
  void clearPixels() => $_clearField(6);

  @$pb.TagNumber(7)
  $fixnum.Int64 get timestampMicros => $_getI64(6);
  @$pb.TagNumber(7)
  set timestampMicros($fixnum.Int64 value) => $_setInt64(6, value);
  @$pb.TagNumber(7)
  $core.bool hasTimestampMicros() => $_has(6);
  @$pb.TagNumber(7)
  void clearTimestampMicros() => $_clearField(7);

  @$pb.TagNumber(8)
  $core.bool get inSharedBuffer => $_getBF(7);
  @$pb.TagNumber(8)
  set inSharedBuffer($core.bool value) => $_setBool(7, value);
  @$pb.TagNumber(8)
  $core.bool hasInSharedBuffer() => $_has(7);
  @$pb.TagNumber(8)
  void clearInSharedBuffer() => $_clearField(8);

  @$pb.TagNumber(9)
  $core.int get bufferIndex => $_getIZ(8);
  @$pb.TagNumber(9)
  set bufferIndex($core.int value) => $_setUnsignedInt32(8, value);
  @$pb.TagNumber(9)
  $core.bool hasBufferIndex() => $_has(8);
  @$pb.TagNumber(9)
  void clearBufferIndex() => $_clearField(9);

  /// The frame is GPU buffer buffer_index of GpuBuffers generation
  /// gpu_generation; pixels are empty.
  @$pb.TagNumber(10)
  $core.bool get inGpuBuffer => $_getBF(9);
  @$pb.TagNumber(10)
  set inGpuBuffer($core.bool value) => $_setBool(9, value);
  @$pb.TagNumber(10)
  $core.bool hasInGpuBuffer() => $_has(9);
  @$pb.TagNumber(10)
  void clearInGpuBuffer() => $_clearField(10);

  @$pb.TagNumber(11)
  $core.int get gpuGeneration => $_getIZ(10);
  @$pb.TagNumber(11)
  set gpuGeneration($core.int value) => $_setUnsignedInt32(10, value);
  @$pb.TagNumber(11)
  $core.bool hasGpuGeneration() => $_has(10);
  @$pb.TagNumber(11)
  void clearGpuGeneration() => $_clearField(11);
}

/// A set of same-sized GPU buffers the engine renders into, one frame each,
/// exported as DRM dmabufs. Their file descriptors are not here: a native
/// client takes them from the runner's GPU socket, where this message is sent
/// again with one descriptor per buffer riding along, in index order. A new
/// set, with a higher generation, replaces the old one on resize.
class GpuBuffers extends $pb.GeneratedMessage {
  factory GpuBuffers({
    $core.int? generation,
    $core.int? count,
    $core.int? width,
    $core.int? height,
    $core.int? fourcc,
    $fixnum.Int64? modifier,
    $core.Iterable<$core.int>? strides,
    $core.Iterable<$core.int>? offsets,
    $core.String? socket,
  }) {
    final result = GpuBuffers._();
    if (generation != null) result.generation = generation;
    if (count != null) result.count = count;
    if (width != null) result.width = width;
    if (height != null) result.height = height;
    if (fourcc != null) result.fourcc = fourcc;
    if (modifier != null) result.modifier = modifier;
    if (strides != null) result.strides.addAll(strides);
    if (offsets != null) result.offsets.addAll(offsets);
    if (socket != null) result.socket = socket;
    return result;
  }

  GpuBuffers._();

  factory GpuBuffers.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GpuBuffers()..mergeFromBuffer(data, registry);
  factory GpuBuffers.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      GpuBuffers()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'GpuBuffers',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'raccoon.v1'),
      createEmptyInstance: GpuBuffers.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'generation', fieldType: $pb.PbFieldType.OU3)
    ..aI(2, _omitFieldNames ? '' : 'count', fieldType: $pb.PbFieldType.OU3)
    ..aI(3, _omitFieldNames ? '' : 'width', fieldType: $pb.PbFieldType.OU3)
    ..aI(4, _omitFieldNames ? '' : 'height', fieldType: $pb.PbFieldType.OU3)
    ..aI(5, _omitFieldNames ? '' : 'fourcc', fieldType: $pb.PbFieldType.OU3)
    ..a<$fixnum.Int64>(
        6, _omitFieldNames ? '' : 'modifier', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..p<$core.int>(7, _omitFieldNames ? '' : 'strides', $pb.PbFieldType.KU3)
    ..p<$core.int>(8, _omitFieldNames ? '' : 'offsets', $pb.PbFieldType.KU3)
    ..aOS(9, _omitFieldNames ? '' : 'socket')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GpuBuffers clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  GpuBuffers copyWith(void Function(GpuBuffers) updates) =>
      super.copyWith((message) => updates(message as GpuBuffers)) as GpuBuffers;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use GpuBuffers() / GpuBuffers.new instead')
  static GpuBuffers create() => GpuBuffers._();
  static $pb.GeneratedMessage $_createMessage() => GpuBuffers._();
  @$core.override
  GpuBuffers createEmptyInstance() => GpuBuffers._();
  @$core.pragma('dart2js:noInline')
  static GpuBuffers getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<GpuBuffers>(GpuBuffers.$_createMessage);
  static GpuBuffers? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get generation => $_getIZ(0);
  @$pb.TagNumber(1)
  set generation($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasGeneration() => $_has(0);
  @$pb.TagNumber(1)
  void clearGeneration() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.int get count => $_getIZ(1);
  @$pb.TagNumber(2)
  set count($core.int value) => $_setUnsignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasCount() => $_has(1);
  @$pb.TagNumber(2)
  void clearCount() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.int get width => $_getIZ(2);
  @$pb.TagNumber(3)
  set width($core.int value) => $_setUnsignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasWidth() => $_has(2);
  @$pb.TagNumber(3)
  void clearWidth() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.int get height => $_getIZ(3);
  @$pb.TagNumber(4)
  set height($core.int value) => $_setUnsignedInt32(3, value);
  @$pb.TagNumber(4)
  $core.bool hasHeight() => $_has(3);
  @$pb.TagNumber(4)
  void clearHeight() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.int get fourcc => $_getIZ(4);
  @$pb.TagNumber(5)
  set fourcc($core.int value) => $_setUnsignedInt32(4, value);
  @$pb.TagNumber(5)
  $core.bool hasFourcc() => $_has(4);
  @$pb.TagNumber(5)
  void clearFourcc() => $_clearField(5);

  @$pb.TagNumber(6)
  $fixnum.Int64 get modifier => $_getI64(5);
  @$pb.TagNumber(6)
  set modifier($fixnum.Int64 value) => $_setInt64(5, value);
  @$pb.TagNumber(6)
  $core.bool hasModifier() => $_has(5);
  @$pb.TagNumber(6)
  void clearModifier() => $_clearField(6);

  @$pb.TagNumber(7)
  $pb.PbList<$core.int> get strides => $_getList(6);

  @$pb.TagNumber(8)
  $pb.PbList<$core.int> get offsets => $_getList(7);

  @$pb.TagNumber(9)
  $core.String get socket => $_getSZ(8);
  @$pb.TagNumber(9)
  set socket($core.String value) => $_setString(8, value);
  @$pb.TagNumber(9)
  $core.bool hasSocket() => $_has(8);
  @$pb.TagNumber(9)
  void clearSocket() => $_clearField(9);
}

/// A set of same-sized shared buffers. Their file descriptors travel with this
/// message as ancillary data, in index order. Replaces any earlier set.
class SharedBuffers extends $pb.GeneratedMessage {
  factory SharedBuffers({
    $core.int? count,
    $fixnum.Int64? size,
  }) {
    final result = SharedBuffers._();
    if (count != null) result.count = count;
    if (size != null) result.size = size;
    return result;
  }

  SharedBuffers._();

  factory SharedBuffers.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SharedBuffers()..mergeFromBuffer(data, registry);
  factory SharedBuffers.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SharedBuffers()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SharedBuffers',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'raccoon.v1'),
      createEmptyInstance: SharedBuffers.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'count', fieldType: $pb.PbFieldType.OU3)
    ..a<$fixnum.Int64>(2, _omitFieldNames ? '' : 'size', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SharedBuffers clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SharedBuffers copyWith(void Function(SharedBuffers) updates) =>
      super.copyWith((message) => updates(message as SharedBuffers))
          as SharedBuffers;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use SharedBuffers() / SharedBuffers.new instead')
  static SharedBuffers create() => SharedBuffers._();
  static $pb.GeneratedMessage $_createMessage() => SharedBuffers._();
  @$core.override
  SharedBuffers createEmptyInstance() => SharedBuffers._();
  @$core.pragma('dart2js:noInline')
  static SharedBuffers getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<SharedBuffers>(
          SharedBuffers.$_createMessage);
  static SharedBuffers? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get count => $_getIZ(0);
  @$pb.TagNumber(1)
  set count($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasCount() => $_has(0);
  @$pb.TagNumber(1)
  void clearCount() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get size => $_getI64(1);
  @$pb.TagNumber(2)
  set size($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasSize() => $_has(1);
  @$pb.TagNumber(2)
  void clearSize() => $_clearField(2);
}

class VmService extends $pb.GeneratedMessage {
  factory VmService({
    $core.String? uri,
  }) {
    final result = VmService._();
    if (uri != null) result.uri = uri;
    return result;
  }

  VmService._();

  factory VmService.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      VmService()..mergeFromBuffer(data, registry);
  factory VmService.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      VmService()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'VmService',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'raccoon.v1'),
      createEmptyInstance: VmService.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'uri')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  VmService clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  VmService copyWith(void Function(VmService) updates) =>
      super.copyWith((message) => updates(message as VmService)) as VmService;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use VmService() / VmService.new instead')
  static VmService create() => VmService._();
  static $pb.GeneratedMessage $_createMessage() => VmService._();
  @$core.override
  VmService createEmptyInstance() => VmService._();
  @$core.pragma('dart2js:noInline')
  static VmService getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<VmService>(VmService.$_createMessage);
  static VmService? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get uri => $_getSZ(0);
  @$pb.TagNumber(1)
  set uri($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasUri() => $_has(0);
  @$pb.TagNumber(1)
  void clearUri() => $_clearField(1);
}

class LogLine extends $pb.GeneratedMessage {
  factory LogLine({
    $core.String? tag,
    $core.String? message,
  }) {
    final result = LogLine._();
    if (tag != null) result.tag = tag;
    if (message != null) result.message = message;
    return result;
  }

  LogLine._();

  factory LogLine.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      LogLine()..mergeFromBuffer(data, registry);
  factory LogLine.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      LogLine()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'LogLine',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'raccoon.v1'),
      createEmptyInstance: LogLine.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'tag')
    ..aOS(2, _omitFieldNames ? '' : 'message')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LogLine clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  LogLine copyWith(void Function(LogLine) updates) =>
      super.copyWith((message) => updates(message as LogLine)) as LogLine;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use LogLine() / LogLine.new instead')
  static LogLine create() => LogLine._();
  static $pb.GeneratedMessage $_createMessage() => LogLine._();
  @$core.override
  LogLine createEmptyInstance() => LogLine._();
  @$core.pragma('dart2js:noInline')
  static LogLine getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<LogLine>(LogLine.$_createMessage);
  static LogLine? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get tag => $_getSZ(0);
  @$pb.TagNumber(1)
  set tag($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasTag() => $_has(0);
  @$pb.TagNumber(1)
  void clearTag() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get message => $_getSZ(1);
  @$pb.TagNumber(2)
  set message($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMessage() => $_has(1);
  @$pb.TagNumber(2)
  void clearMessage() => $_clearField(2);
}

class Exited extends $pb.GeneratedMessage {
  factory Exited({
    $core.int? code,
  }) {
    final result = Exited._();
    if (code != null) result.code = code;
    return result;
  }

  Exited._();

  factory Exited.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Exited()..mergeFromBuffer(data, registry);
  factory Exited.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Exited()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Exited',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'raccoon.v1'),
      createEmptyInstance: Exited.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'code')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Exited clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Exited copyWith(void Function(Exited) updates) =>
      super.copyWith((message) => updates(message as Exited)) as Exited;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Exited() / Exited.new instead')
  static Exited create() => Exited._();
  static $pb.GeneratedMessage $_createMessage() => Exited._();
  @$core.override
  Exited createEmptyInstance() => Exited._();
  @$core.pragma('dart2js:noInline')
  static Exited getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Exited>(Exited.$_createMessage);
  static Exited? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get code => $_getIZ(0);
  @$pb.TagNumber(1)
  set code($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasCode() => $_has(0);
  @$pb.TagNumber(1)
  void clearCode() => $_clearField(1);
}

/// A platform channel message the app sent, for the client to answer. The
/// client serves channels the way a desktop embedder's plugins would; a
/// response_id of 0 means the app expects no reply.
class PlatformMessage extends $pb.GeneratedMessage {
  factory PlatformMessage({
    $fixnum.Int64? responseId,
    $core.String? channel,
    $core.List<$core.int>? data,
  }) {
    final result = PlatformMessage._();
    if (responseId != null) result.responseId = responseId;
    if (channel != null) result.channel = channel;
    if (data != null) result.data = data;
    return result;
  }

  PlatformMessage._();

  factory PlatformMessage.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      PlatformMessage()..mergeFromBuffer(data, registry);
  factory PlatformMessage.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      PlatformMessage()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PlatformMessage',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'raccoon.v1'),
      createEmptyInstance: PlatformMessage.$_createMessage)
    ..a<$fixnum.Int64>(
        1, _omitFieldNames ? '' : 'responseId', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aOS(2, _omitFieldNames ? '' : 'channel')
    ..a<$core.List<$core.int>>(
        3, _omitFieldNames ? '' : 'data', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PlatformMessage clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PlatformMessage copyWith(void Function(PlatformMessage) updates) =>
      super.copyWith((message) => updates(message as PlatformMessage))
          as PlatformMessage;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use PlatformMessage() / PlatformMessage.new instead')
  static PlatformMessage create() => PlatformMessage._();
  static $pb.GeneratedMessage $_createMessage() => PlatformMessage._();
  @$core.override
  PlatformMessage createEmptyInstance() => PlatformMessage._();
  @$core.pragma('dart2js:noInline')
  static PlatformMessage getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<PlatformMessage>(
          PlatformMessage.$_createMessage);
  static PlatformMessage? _defaultInstance;

  @$pb.TagNumber(1)
  $fixnum.Int64 get responseId => $_getI64(0);
  @$pb.TagNumber(1)
  set responseId($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasResponseId() => $_has(0);
  @$pb.TagNumber(1)
  void clearResponseId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get channel => $_getSZ(1);
  @$pb.TagNumber(2)
  set channel($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasChannel() => $_has(1);
  @$pb.TagNumber(2)
  void clearChannel() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.List<$core.int> get data => $_getN(2);
  @$pb.TagNumber(3)
  set data($core.List<$core.int> value) => $_setBytes(2, value);
  @$pb.TagNumber(3)
  $core.bool hasData() => $_has(2);
  @$pb.TagNumber(3)
  void clearData() => $_clearField(3);
}

/// The app's active text field, whenever it changes; active=false once no
/// field has focus. A client with an input method mirrors it there.
class TextField extends $pb.GeneratedMessage {
  factory TextField({
    $core.bool? active,
    $core.String? text,
    $core.int? selectionBase,
    $core.int? selectionExtent,
    $core.int? composingBase,
    $core.int? composingExtent,
    $core.bool? multiline,
    $core.String? inputAction,
    $core.bool? obscure,
  }) {
    final result = TextField._();
    if (active != null) result.active = active;
    if (text != null) result.text = text;
    if (selectionBase != null) result.selectionBase = selectionBase;
    if (selectionExtent != null) result.selectionExtent = selectionExtent;
    if (composingBase != null) result.composingBase = composingBase;
    if (composingExtent != null) result.composingExtent = composingExtent;
    if (multiline != null) result.multiline = multiline;
    if (inputAction != null) result.inputAction = inputAction;
    if (obscure != null) result.obscure = obscure;
    return result;
  }

  TextField._();

  factory TextField.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      TextField()..mergeFromBuffer(data, registry);
  factory TextField.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      TextField()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TextField',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'raccoon.v1'),
      createEmptyInstance: TextField.$_createMessage)
    ..aOB(1, _omitFieldNames ? '' : 'active')
    ..aOS(2, _omitFieldNames ? '' : 'text')
    ..aI(3, _omitFieldNames ? '' : 'selectionBase')
    ..aI(4, _omitFieldNames ? '' : 'selectionExtent')
    ..aI(5, _omitFieldNames ? '' : 'composingBase')
    ..aI(6, _omitFieldNames ? '' : 'composingExtent')
    ..aOB(7, _omitFieldNames ? '' : 'multiline')
    ..aOS(8, _omitFieldNames ? '' : 'inputAction')
    ..aOB(9, _omitFieldNames ? '' : 'obscure')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TextField clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TextField copyWith(void Function(TextField) updates) =>
      super.copyWith((message) => updates(message as TextField)) as TextField;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use TextField() / TextField.new instead')
  static TextField create() => TextField._();
  static $pb.GeneratedMessage $_createMessage() => TextField._();
  @$core.override
  TextField createEmptyInstance() => TextField._();
  @$core.pragma('dart2js:noInline')
  static TextField getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TextField>(TextField.$_createMessage);
  static TextField? _defaultInstance;

  @$pb.TagNumber(1)
  $core.bool get active => $_getBF(0);
  @$pb.TagNumber(1)
  set active($core.bool value) => $_setBool(0, value);
  @$pb.TagNumber(1)
  $core.bool hasActive() => $_has(0);
  @$pb.TagNumber(1)
  void clearActive() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get text => $_getSZ(1);
  @$pb.TagNumber(2)
  set text($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasText() => $_has(1);
  @$pb.TagNumber(2)
  void clearText() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.int get selectionBase => $_getIZ(2);
  @$pb.TagNumber(3)
  set selectionBase($core.int value) => $_setSignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasSelectionBase() => $_has(2);
  @$pb.TagNumber(3)
  void clearSelectionBase() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.int get selectionExtent => $_getIZ(3);
  @$pb.TagNumber(4)
  set selectionExtent($core.int value) => $_setSignedInt32(3, value);
  @$pb.TagNumber(4)
  $core.bool hasSelectionExtent() => $_has(3);
  @$pb.TagNumber(4)
  void clearSelectionExtent() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.int get composingBase => $_getIZ(4);
  @$pb.TagNumber(5)
  set composingBase($core.int value) => $_setSignedInt32(4, value);
  @$pb.TagNumber(5)
  $core.bool hasComposingBase() => $_has(4);
  @$pb.TagNumber(5)
  void clearComposingBase() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.int get composingExtent => $_getIZ(5);
  @$pb.TagNumber(6)
  set composingExtent($core.int value) => $_setSignedInt32(5, value);
  @$pb.TagNumber(6)
  $core.bool hasComposingExtent() => $_has(5);
  @$pb.TagNumber(6)
  void clearComposingExtent() => $_clearField(6);

  @$pb.TagNumber(7)
  $core.bool get multiline => $_getBF(6);
  @$pb.TagNumber(7)
  set multiline($core.bool value) => $_setBool(6, value);
  @$pb.TagNumber(7)
  $core.bool hasMultiline() => $_has(6);
  @$pb.TagNumber(7)
  void clearMultiline() => $_clearField(7);

  @$pb.TagNumber(8)
  $core.String get inputAction => $_getSZ(7);
  @$pb.TagNumber(8)
  set inputAction($core.String value) => $_setString(7, value);
  @$pb.TagNumber(8)
  $core.bool hasInputAction() => $_has(7);
  @$pb.TagNumber(8)
  void clearInputAction() => $_clearField(8);

  @$pb.TagNumber(9)
  $core.bool get obscure => $_getBF(8);
  @$pb.TagNumber(9)
  set obscure($core.bool value) => $_setBool(8, value);
  @$pb.TagNumber(9)
  $core.bool hasObscure() => $_has(8);
  @$pb.TagNumber(9)
  void clearObscure() => $_clearField(9);
}

/// The runner has a client already; the connection closes after this.
class Busy extends $pb.GeneratedMessage {
  factory Busy({
    $core.int? pid,
  }) {
    final result = Busy._();
    if (pid != null) result.pid = pid;
    return result;
  }

  Busy._();

  factory Busy.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Busy()..mergeFromBuffer(data, registry);
  factory Busy.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Busy()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Busy',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'raccoon.v1'),
      createEmptyInstance: Busy.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'pid', fieldType: $pb.PbFieldType.OU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Busy clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Busy copyWith(void Function(Busy) updates) =>
      super.copyWith((message) => updates(message as Busy)) as Busy;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Busy() / Busy.new instead')
  static Busy create() => Busy._();
  static $pb.GeneratedMessage $_createMessage() => Busy._();
  @$core.override
  Busy createEmptyInstance() => Busy._();
  @$core.pragma('dart2js:noInline')
  static Busy getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Busy>(Busy.$_createMessage);
  static Busy? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get pid => $_getIZ(0);
  @$pb.TagNumber(1)
  set pid($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPid() => $_has(0);
  @$pb.TagNumber(1)
  void clearPid() => $_clearField(1);
}

enum RunnerMessage_Message {
  hello,
  frame,
  vmService,
  log,
  exited,
  platformMessage,
  sharedBuffers,
  busy,
  textField,
  gpuBuffers,
  notSet
}

class RunnerMessage extends $pb.GeneratedMessage {
  factory RunnerMessage({
    RunnerHello? hello,
    Frame? frame,
    VmService? vmService,
    LogLine? log,
    Exited? exited,
    PlatformMessage? platformMessage,
    SharedBuffers? sharedBuffers,
    Busy? busy,
    TextField? textField,
    GpuBuffers? gpuBuffers,
  }) {
    final result = RunnerMessage._();
    if (hello != null) result.hello = hello;
    if (frame != null) result.frame = frame;
    if (vmService != null) result.vmService = vmService;
    if (log != null) result.log = log;
    if (exited != null) result.exited = exited;
    if (platformMessage != null) result.platformMessage = platformMessage;
    if (sharedBuffers != null) result.sharedBuffers = sharedBuffers;
    if (busy != null) result.busy = busy;
    if (textField != null) result.textField = textField;
    if (gpuBuffers != null) result.gpuBuffers = gpuBuffers;
    return result;
  }

  RunnerMessage._();

  factory RunnerMessage.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RunnerMessage()..mergeFromBuffer(data, registry);
  factory RunnerMessage.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RunnerMessage()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, RunnerMessage_Message>
      _RunnerMessage_MessageByTag = {
    1: RunnerMessage_Message.hello,
    2: RunnerMessage_Message.frame,
    3: RunnerMessage_Message.vmService,
    4: RunnerMessage_Message.log,
    5: RunnerMessage_Message.exited,
    6: RunnerMessage_Message.platformMessage,
    7: RunnerMessage_Message.sharedBuffers,
    8: RunnerMessage_Message.busy,
    9: RunnerMessage_Message.textField,
    10: RunnerMessage_Message.gpuBuffers,
    0: RunnerMessage_Message.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RunnerMessage',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'raccoon.v1'),
      createEmptyInstance: RunnerMessage.$_createMessage)
    ..oo(0, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    ..aOM<RunnerHello>(1, _omitFieldNames ? '' : 'hello',
        subBuilder: RunnerHello.$_createMessage)
    ..aOM<Frame>(2, _omitFieldNames ? '' : 'frame',
        subBuilder: Frame.$_createMessage)
    ..aOM<VmService>(3, _omitFieldNames ? '' : 'vmService',
        subBuilder: VmService.$_createMessage)
    ..aOM<LogLine>(4, _omitFieldNames ? '' : 'log',
        subBuilder: LogLine.$_createMessage)
    ..aOM<Exited>(5, _omitFieldNames ? '' : 'exited',
        subBuilder: Exited.$_createMessage)
    ..aOM<PlatformMessage>(6, _omitFieldNames ? '' : 'platformMessage',
        subBuilder: PlatformMessage.$_createMessage)
    ..aOM<SharedBuffers>(7, _omitFieldNames ? '' : 'sharedBuffers',
        subBuilder: SharedBuffers.$_createMessage)
    ..aOM<Busy>(8, _omitFieldNames ? '' : 'busy',
        subBuilder: Busy.$_createMessage)
    ..aOM<TextField>(9, _omitFieldNames ? '' : 'textField',
        subBuilder: TextField.$_createMessage)
    ..aOM<GpuBuffers>(10, _omitFieldNames ? '' : 'gpuBuffers',
        subBuilder: GpuBuffers.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RunnerMessage clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RunnerMessage copyWith(void Function(RunnerMessage) updates) =>
      super.copyWith((message) => updates(message as RunnerMessage))
          as RunnerMessage;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use RunnerMessage() / RunnerMessage.new instead')
  static RunnerMessage create() => RunnerMessage._();
  static $pb.GeneratedMessage $_createMessage() => RunnerMessage._();
  @$core.override
  RunnerMessage createEmptyInstance() => RunnerMessage._();
  @$core.pragma('dart2js:noInline')
  static RunnerMessage getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<RunnerMessage>(
          RunnerMessage.$_createMessage);
  static RunnerMessage? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  @$pb.TagNumber(8)
  @$pb.TagNumber(9)
  @$pb.TagNumber(10)
  RunnerMessage_Message whichMessage() =>
      _RunnerMessage_MessageByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  @$pb.TagNumber(8)
  @$pb.TagNumber(9)
  @$pb.TagNumber(10)
  void clearMessage() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  RunnerHello get hello => $_getN(0);
  @$pb.TagNumber(1)
  set hello(RunnerHello value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasHello() => $_has(0);
  @$pb.TagNumber(1)
  void clearHello() => $_clearField(1);
  @$pb.TagNumber(1)
  RunnerHello ensureHello() => $_ensure(0);

  @$pb.TagNumber(2)
  Frame get frame => $_getN(1);
  @$pb.TagNumber(2)
  set frame(Frame value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasFrame() => $_has(1);
  @$pb.TagNumber(2)
  void clearFrame() => $_clearField(2);
  @$pb.TagNumber(2)
  Frame ensureFrame() => $_ensure(1);

  @$pb.TagNumber(3)
  VmService get vmService => $_getN(2);
  @$pb.TagNumber(3)
  set vmService(VmService value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasVmService() => $_has(2);
  @$pb.TagNumber(3)
  void clearVmService() => $_clearField(3);
  @$pb.TagNumber(3)
  VmService ensureVmService() => $_ensure(2);

  @$pb.TagNumber(4)
  LogLine get log => $_getN(3);
  @$pb.TagNumber(4)
  set log(LogLine value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasLog() => $_has(3);
  @$pb.TagNumber(4)
  void clearLog() => $_clearField(4);
  @$pb.TagNumber(4)
  LogLine ensureLog() => $_ensure(3);

  @$pb.TagNumber(5)
  Exited get exited => $_getN(4);
  @$pb.TagNumber(5)
  set exited(Exited value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasExited() => $_has(4);
  @$pb.TagNumber(5)
  void clearExited() => $_clearField(5);
  @$pb.TagNumber(5)
  Exited ensureExited() => $_ensure(4);

  @$pb.TagNumber(6)
  PlatformMessage get platformMessage => $_getN(5);
  @$pb.TagNumber(6)
  set platformMessage(PlatformMessage value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasPlatformMessage() => $_has(5);
  @$pb.TagNumber(6)
  void clearPlatformMessage() => $_clearField(6);
  @$pb.TagNumber(6)
  PlatformMessage ensurePlatformMessage() => $_ensure(5);

  @$pb.TagNumber(7)
  SharedBuffers get sharedBuffers => $_getN(6);
  @$pb.TagNumber(7)
  set sharedBuffers(SharedBuffers value) => $_setField(7, value);
  @$pb.TagNumber(7)
  $core.bool hasSharedBuffers() => $_has(6);
  @$pb.TagNumber(7)
  void clearSharedBuffers() => $_clearField(7);
  @$pb.TagNumber(7)
  SharedBuffers ensureSharedBuffers() => $_ensure(6);

  @$pb.TagNumber(8)
  Busy get busy => $_getN(7);
  @$pb.TagNumber(8)
  set busy(Busy value) => $_setField(8, value);
  @$pb.TagNumber(8)
  $core.bool hasBusy() => $_has(7);
  @$pb.TagNumber(8)
  void clearBusy() => $_clearField(8);
  @$pb.TagNumber(8)
  Busy ensureBusy() => $_ensure(7);

  @$pb.TagNumber(9)
  TextField get textField => $_getN(8);
  @$pb.TagNumber(9)
  set textField(TextField value) => $_setField(9, value);
  @$pb.TagNumber(9)
  $core.bool hasTextField() => $_has(8);
  @$pb.TagNumber(9)
  void clearTextField() => $_clearField(9);
  @$pb.TagNumber(9)
  TextField ensureTextField() => $_ensure(8);

  @$pb.TagNumber(10)
  GpuBuffers get gpuBuffers => $_getN(9);
  @$pb.TagNumber(10)
  set gpuBuffers(GpuBuffers value) => $_setField(10, value);
  @$pb.TagNumber(10)
  $core.bool hasGpuBuffers() => $_has(9);
  @$pb.TagNumber(10)
  void clearGpuBuffers() => $_clearField(10);
  @$pb.TagNumber(10)
  GpuBuffers ensureGpuBuffers() => $_ensure(9);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');

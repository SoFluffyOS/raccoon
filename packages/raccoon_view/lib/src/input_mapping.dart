import 'package:fixnum/fixnum.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:raccoon/raccoon.dart' as rc;

/// Maps the framework's pointer events onto the runner protocol. Positions are
/// local to the view and scaled by [pixelRatio] into the frame's pixels.
rc.PointerEvent? toRunnerPointer(PointerEvent event, double pixelRatio) {
  final phase = switch (event) {
    PointerDownEvent() => rc.PointerPhase.POINTER_PHASE_DOWN,
    PointerMoveEvent() => rc.PointerPhase.POINTER_PHASE_MOVE,
    PointerUpEvent() => rc.PointerPhase.POINTER_PHASE_UP,
    PointerHoverEvent() => rc.PointerPhase.POINTER_PHASE_HOVER,
    PointerCancelEvent() => rc.PointerPhase.POINTER_PHASE_UP,
    PointerScrollEvent() => rc.PointerPhase.POINTER_PHASE_HOVER,
    _ => null,
  };
  if (phase == null) return null;
  final device = switch (event.kind) {
    PointerDeviceKind.touch => rc.PointerDevice.POINTER_DEVICE_TOUCH,
    _ => rc.PointerDevice.POINTER_DEVICE_MOUSE,
  };
  final scroll = switch (event) {
    PointerScrollEvent(:final scrollDelta) => scrollDelta * pixelRatio,
    _ => Offset.zero,
  };
  return rc.PointerEvent(
    phase: phase,
    x: event.localPosition.dx * pixelRatio,
    y: event.localPosition.dy * pixelRatio,
    buttons: Int64(event.buttons),
    device: device,
    pointerId: event.pointer,
    timestampMicros: Int64(event.timeStamp.inMicroseconds),
    scrollDeltaX: scroll.dx,
    scrollDeltaY: scroll.dy,
  );
}

/// Maps a framework key event onto the runner protocol.
rc.KeyEvent toRunnerKey(KeyEvent event) {
  final kind = switch (event) {
    KeyDownEvent() => rc.KeyKind.KEY_KIND_DOWN,
    KeyRepeatEvent() => rc.KeyKind.KEY_KIND_REPEAT,
    _ => rc.KeyKind.KEY_KIND_UP,
  };
  return rc.KeyEvent(
    kind: kind,
    physical: Int64(event.physicalKey.usbHidUsage),
    logical: Int64(event.logicalKey.keyId),
    character: event.character ?? '',
    timestampMicros: Int64(event.timeStamp.inMicroseconds),
    synthesized: event.synthesized,
  );
}

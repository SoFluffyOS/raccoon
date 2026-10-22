import 'package:fixnum/fixnum.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:raccoon/raccoon.dart' as rc;

/// Maps the framework's pointer events onto the runner protocol. Positions
/// and pans are local to the view and scaled by [pixelRatio] into the
/// frame's pixels. A trackpad gesture (two-finger scrolling, a pinch) comes
/// as pan-zoom events and goes on as such: the app's scrollables treat it
/// as the drag it is.
rc.PointerEvent? toRunnerPointer(PointerEvent event, double pixelRatio) {
  final phase = switch (event) {
    PointerDownEvent() => rc.PointerPhase.POINTER_PHASE_DOWN,
    PointerMoveEvent() => rc.PointerPhase.POINTER_PHASE_MOVE,
    PointerUpEvent() => rc.PointerPhase.POINTER_PHASE_UP,
    PointerHoverEvent() => rc.PointerPhase.POINTER_PHASE_HOVER,
    PointerCancelEvent() => rc.PointerPhase.POINTER_PHASE_UP,
    PointerScrollEvent() => rc.PointerPhase.POINTER_PHASE_HOVER,
    PointerPanZoomStartEvent() => rc.PointerPhase.POINTER_PHASE_PAN_ZOOM_START,
    PointerPanZoomUpdateEvent() =>
      rc.PointerPhase.POINTER_PHASE_PAN_ZOOM_UPDATE,
    PointerPanZoomEndEvent() => rc.PointerPhase.POINTER_PHASE_PAN_ZOOM_END,
    _ => null,
  };
  if (phase == null) return null;
  final device = switch (event.kind) {
    PointerDeviceKind.touch => rc.PointerDevice.POINTER_DEVICE_TOUCH,
    PointerDeviceKind.trackpad => rc.PointerDevice.POINTER_DEVICE_TRACKPAD,
    _ => rc.PointerDevice.POINTER_DEVICE_MOUSE,
  };
  final scroll = switch (event) {
    PointerScrollEvent(:final scrollDelta) => scrollDelta * pixelRatio,
    _ => Offset.zero,
  };
  // The pan is the whole of it since the gesture began, as the engine wants.
  final (pan, scale, rotation) = switch (event) {
    PointerPanZoomUpdateEvent(:final localPan, :final scale, :final rotation) =>
      (localPan * pixelRatio, scale, rotation),
    _ => (Offset.zero, 1.0, 0.0),
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
    panX: pan.dx,
    panY: pan.dy,
    scale: scale,
    rotation: rotation,
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

/// Whether a key edits text rather than typing it: Backspace, Delete, the
/// arrows, Home, End, Enter, Tab, Escape.
bool isEditingKey(KeyEvent event) => _editingKeys.contains(event.logicalKey);

final _editingKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.backspace,
  LogicalKeyboardKey.delete,
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.home,
  LogicalKeyboardKey.end,
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.numpadEnter,
  LogicalKeyboardKey.tab,
  LogicalKeyboardKey.escape,
};

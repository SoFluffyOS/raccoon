import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raccoon/raccoon.dart' as rc;
import 'package:raccoon_view/src/input_mapping.dart';

void main() {
  test('a mouse is one pointer, however many clicks and pans it makes', () {
    // Flutter numbers each click and each trackpad pan anew in `pointer`;
    // the runner must see one device, or every old one stays hovering (#88).
    final events = <PointerEvent>[
      const PointerHoverEvent(
        kind: PointerDeviceKind.mouse,
        device: 3,
        pointer: 1,
        position: Offset(10, 10),
      ),
      const PointerDownEvent(
        kind: PointerDeviceKind.mouse,
        device: 3,
        pointer: 2,
        position: Offset(10, 10),
      ),
      const PointerUpEvent(
        kind: PointerDeviceKind.mouse,
        device: 3,
        pointer: 2,
        position: Offset(10, 10),
      ),
      const PointerScrollEvent(
        kind: PointerDeviceKind.mouse,
        device: 3,
        position: Offset(20, 20),
        scrollDelta: Offset(0, 40),
      ),
      const PointerHoverEvent(
        kind: PointerDeviceKind.mouse,
        device: 3,
        pointer: 4,
        position: Offset(30, 30),
      ),
    ];
    final ids = {
      for (final event in events) toRunnerPointer(event, 2)?.pointerId,
    };
    expect(ids, {3});
  });

  test('a trackpad gesture is its device too', () {
    const start = PointerPanZoomStartEvent(device: 5, pointer: 9);
    const update = PointerPanZoomUpdateEvent(
      device: 5,
      pointer: 9,
      pan: Offset(0, 12),
    );
    expect(toRunnerPointer(start, 2)?.pointerId, 5);
    expect(toRunnerPointer(update, 2)?.pointerId, 5);
  });

  test('each finger keeps a pointer of its own', () {
    const first = PointerDownEvent(
      kind: PointerDeviceKind.touch,
      device: 1,
      pointer: 7,
    );
    const second = PointerDownEvent(
      kind: PointerDeviceKind.touch,
      device: 2,
      pointer: 8,
    );
    expect(toRunnerPointer(first, 2)?.pointerId, 7);
    expect(toRunnerPointer(second, 2)?.pointerId, 8);
  });

  // #133: a cancel went on as a release, so a button under it fired.
  test('a cancel is a cancel, and a mouse leaving is its removal', () {
    expect(
      toRunnerPointer(const PointerCancelEvent(device: 1), 2)?.phase,
      rc.PointerPhase.POINTER_PHASE_CANCEL,
    );
    expect(
      toRunnerPointer(const PointerExitEvent(device: 1), 2)?.phase,
      rc.PointerPhase.POINTER_PHASE_REMOVE,
    );
  });
}

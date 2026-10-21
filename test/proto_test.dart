import 'package:fixnum/fixnum.dart';
import 'package:raccoon/raccoon.dart';
import 'package:test/test.dart';

void main() {
  test('client messages round-trip through the wire format', () {
    final message = ClientMessage(
      pointer: PointerEvent(
        phase: PointerPhase.POINTER_PHASE_DOWN,
        x: 400,
        y: 300,
        buttons: Int64(1),
        device: PointerDevice.POINTER_DEVICE_MOUSE,
      ),
    );

    final decoded = ClientMessage.fromBuffer(message.writeToBuffer());

    expect(decoded.whichMessage(), ClientMessage_Message.pointer);
    expect(decoded.pointer.phase, PointerPhase.POINTER_PHASE_DOWN);
    expect(decoded.pointer.x, 400);
    expect(decoded.pointer.buttons.toInt(), 1);
  });

  test('frames carry their pixels', () {
    final message = RunnerMessage(
      frame: Frame(
        sequence: Int64(7),
        width: 2,
        height: 1,
        rowBytes: 8,
        format: PixelFormat.PIXEL_FORMAT_BGRA8888,
        pixels: [1, 2, 3, 4, 5, 6, 7, 8],
      ),
    );

    final decoded = RunnerMessage.fromBuffer(message.writeToBuffer());

    expect(decoded.whichMessage(), RunnerMessage_Message.frame);
    expect(decoded.frame.sequence.toInt(), 7);
    expect(decoded.frame.pixels, hasLength(8));
  });
}

import 'dart:async';

import 'package:fixnum/fixnum.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raccoon/raccoon.dart' as rc;
import 'package:raccoon_runtime/raccoon_runtime.dart' show RunnerConnection;
import 'package:raccoon_view/raccoon_view.dart';

class _FakeConnection implements RunnerConnection {
  final _frames = StreamController<rc.Frame>.broadcast();
  final resizes = <(int, int, double)>[];
  final pointers = <rc.PointerEvent>[];
  final keys = <rc.KeyEvent>[];

  @override
  Stream<rc.Frame> get frames => _frames.stream;

  void emit(rc.Frame frame) => _frames.add(frame);

  @override
  void resize(int width, int height, double pixelRatio) =>
      resizes.add((width, height, pixelRatio));

  @override
  void sendPointer(rc.PointerEvent event) => pointers.add(event);

  @override
  void sendKey(rc.KeyEvent event) => keys.add(event);
}

rc.Frame _solidFrame(int width, int height) => rc.Frame(
  sequence: Int64(1),
  width: width,
  height: height,
  rowBytes: width * 4,
  format: rc.PixelFormat.PIXEL_FORMAT_BGRA8888,
  pixels: List.filled(width * height * 4, 0x80),
);

void main() {
  testWidgets('sends its size scaled by the pixel ratio', (tester) async {
    final connection = _FakeConnection();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(devicePixelRatio: 2),
        child: Center(
          child: SizedBox(
            width: 300,
            height: 200,
            child: RaccoonView(connection: connection),
          ),
        ),
      ),
    );

    expect(connection.resizes, [(600, 400, 2.0)]);
  });

  testWidgets('a pixel ratio override replaces the display ratio', (
    tester,
  ) async {
    final connection = _FakeConnection();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(devicePixelRatio: 2),
        child: Center(
          child: SizedBox(
            width: 100,
            height: 50,
            child: RaccoonView(connection: connection, pixelRatio: 3),
          ),
        ),
      ),
    );

    expect(connection.resizes, [(300, 150, 3.0)]);
  });

  testWidgets('shows the latest decoded frame', (tester) async {
    final connection = _FakeConnection();
    // Decoding needs the real event loop, and stream events are delivered in
    // the zone that subscribed, so the widget is pumped inside runAsync too.
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(),
          child: RaccoonView(connection: connection),
        ),
      );
      connection.emit(_solidFrame(4, 3));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    final image = tester.widget<RawImage>(find.byType(RawImage)).image;
    expect(image, isNotNull);
    expect(image?.width, 4);
    expect(image?.height, 3);
  });

  testWidgets('forwards taps as down and up in frame pixels', (tester) async {
    final connection = _FakeConnection();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(devicePixelRatio: 2),
        child: RaccoonView(connection: connection),
      ),
    );

    await tester.tapAt(const Offset(10, 20));

    final phases = connection.pointers.map((p) => p.phase).toList();
    expect(phases, [
      rc.PointerPhase.POINTER_PHASE_DOWN,
      rc.PointerPhase.POINTER_PHASE_UP,
    ]);
    expect(connection.pointers.first.x, 20);
    expect(connection.pointers.first.y, 40);
    expect(connection.pointers.first.buttons.toInt(), 1);
  });

  testWidgets('forwards key events', (tester) async {
    final connection = _FakeConnection();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(),
        child: RaccoonView(connection: connection),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);

    expect(connection.keys.map((k) => k.kind), [
      rc.KeyKind.KEY_KIND_DOWN,
      rc.KeyKind.KEY_KIND_UP,
    ]);
    expect(
      connection.keys.first.logical.toInt(),
      LogicalKeyboardKey.keyA.keyId,
    );
  });

  testWidgets('a runner hanging up shows as disconnected', (tester) async {
    final connection = _FakeConnection();
    var disconnected = 0;
    await tester.pumpWidget(
      RaccoonView(connection: connection, onDisconnected: () => disconnected++),
    );
    connection._frames.addError(StateError('hung up'));
    await tester.pump();
    expect(find.text('Runner disconnected'), findsOneWidget);
    expect(disconnected, 1);
  });
}

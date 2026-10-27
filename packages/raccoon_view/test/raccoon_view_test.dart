import 'dart:async';

import 'package:fixnum/fixnum.dart';
import 'package:flutter/gestures.dart';
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

/// Counts how often it paints, to tell whether a repaint reached it.
class _PaintCounter extends LeafRenderObjectWidget {
  const _PaintCounter(this.paints);

  final List<int> paints;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPaintCounter(paints);
}

class _RenderPaintCounter extends RenderBox {
  _RenderPaintCounter(this.paints);

  final List<int> paints;

  @override
  void performLayout() => size = constraints.biggest;

  @override
  void paint(PaintingContext context, Offset offset) => paints[0]++;
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

  // #107: the size goes again to a new connection, though nothing moved.
  testWidgets('sends its size to a new connection of the same size', (
    tester,
  ) async {
    final first = _FakeConnection();
    final second = _FakeConnection();
    Widget view(RunnerConnection connection) => MediaQuery(
      data: const MediaQueryData(devicePixelRatio: 2),
      child: Center(
        child: SizedBox(
          width: 300,
          height: 200,
          child: RaccoonView(connection: connection),
        ),
      ),
    );
    await tester.pumpWidget(view(first));
    await tester.pumpWidget(view(second));

    expect(first.resizes, [(600, 400, 2.0)]);
    expect(second.resizes, [(600, 400, 2.0)]);
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

  // #107: a frame repaints the view, not what sits around it.
  testWidgets('a frame does not repaint the widgets beside the view', (
    tester,
  ) async {
    final connection = _FakeConnection();
    final paints = [0];
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Row(
              children: [
                SizedBox(width: 50, child: _PaintCounter(paints)),
                Expanded(child: RaccoonView(connection: connection)),
              ],
            ),
          ),
        ),
      );
      for (var i = 0; i < 3; i++) {
        connection.emit(_solidFrame(4, 3));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
    });

    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(paints[0], 1);
  });

  // #133: a mouse that left the view left the app's hover states on.
  testWidgets('a mouse that leaves the view leaves the app too', (
    tester,
  ) async {
    final connection = _FakeConnection();
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 100, height: 100),
        ),
      ),
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 100,
            height: 100,
            child: RaccoonView(connection: connection, pixelRatio: 1),
          ),
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(300, 300));
    // Leaving before it ever came in sends nothing.
    await mouse.moveTo(const Offset(200, 200));
    await mouse.moveTo(const Offset(50, 50));
    await mouse.moveTo(const Offset(300, 300));
    await tester.pump();

    final phases = connection.pointers.map((p) => p.phase).toList();
    expect(phases, [
      rc.PointerPhase.POINTER_PHASE_HOVER,
      rc.PointerPhase.POINTER_PHASE_REMOVE,
    ]);
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
    // A finger lifted is gone, as a touchscreen says (#207).
    expect(phases, [
      rc.PointerPhase.POINTER_PHASE_DOWN,
      rc.PointerPhase.POINTER_PHASE_UP,
      rc.PointerPhase.POINTER_PHASE_REMOVE,
    ]);
    expect(connection.pointers.first.x, 20);
    expect(connection.pointers.first.y, 40);
    expect(connection.pointers.first.buttons.toInt(), 1);
  });

  testWidgets(
    'forwards a trackpad gesture as pan-zoom, the pan in frame pixels',
    (tester) async {
      final connection = _FakeConnection();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(devicePixelRatio: 2),
          child: RaccoonView(connection: connection),
        ),
      );

      // Two-finger scrolling: the framework delivers it this way, not as a
      // scroll signal, so the app's scrollables see the drag it is.
      final pointer = TestPointer(1, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(
        pointer.panZoomStart(const Offset(10, 20)),
      );
      await tester.sendEventToBinding(
        pointer.panZoomUpdate(const Offset(10, 20), pan: const Offset(0, -30)),
      );
      await tester.sendEventToBinding(pointer.panZoomEnd());

      final phases = connection.pointers.map((p) => p.phase).toList();
      expect(phases, [
        rc.PointerPhase.POINTER_PHASE_PAN_ZOOM_START,
        rc.PointerPhase.POINTER_PHASE_PAN_ZOOM_UPDATE,
        rc.PointerPhase.POINTER_PHASE_PAN_ZOOM_END,
      ]);
      final update = connection.pointers[1];
      expect(update.device, rc.PointerDevice.POINTER_DEVICE_TRACKPAD);
      expect(update.x, 20);
      expect(update.y, 40);
      expect(update.panX, 0);
      expect(update.panY, -60);
      expect(update.scale, 1);
      expect(update.rotation, 0);
    },
  );

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

  // #133: focus that left mid-press left the key held in the app, and an
  // up whose down the app never saw failed its keyboard's checks.
  testWidgets('keys held when focus leaves are let go, and stray ups stay', (
    tester,
  ) async {
    final connection = _FakeConnection();
    final elsewhere = FocusNode();
    addTearDown(elsewhere.dispose);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(),
        child: Column(
          children: [
            Focus(focusNode: elsewhere, child: const SizedBox(height: 10)),
            Expanded(
              child: RaccoonView(connection: connection, autofocus: true),
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyB);
    expect(connection.keys, isEmpty);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    elsewhere.requestFocus();
    await tester.pump();
    expect(connection.keys.map((k) => k.kind), [
      rc.KeyKind.KEY_KIND_DOWN,
      rc.KeyKind.KEY_KIND_UP,
    ]);
    expect(connection.keys.last.synthesized, isTrue);
    expect(
      connection.keys.last.logical.toInt(),
      LogicalKeyboardKey.metaLeft.keyId,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    expect(connection.keys, hasLength(2));
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

  testWidgets('a click into the app focuses the view, so keys follow', (
    tester,
  ) async {
    final connection = _FakeConnection();
    await tester.pumpWidget(
      Column(
        children: [
          const SizedBox(
            height: 20,
            child: Focus(autofocus: true, child: SizedBox()),
          ),
          Expanded(child: RaccoonView(connection: connection)),
        ],
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(connection.keys, isEmpty);

    await tester.tapAt(tester.getCenter(find.byType(RaccoonView)));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(connection.keys, isNotEmpty);
  });

  testWidgets('with touch, a mouse press goes as a finger, then is gone', (
    tester,
  ) async {
    // #207: a phone app's lists drag for a finger, not for a mouse.
    final connection = _FakeConnection();
    await tester.pumpWidget(
      RaccoonView(connection: connection, pixelRatio: 1, touch: true),
    );
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(5, 5));
    await gesture.moveTo(const Offset(10, 10));
    await gesture.down(const Offset(10, 10));
    await gesture.moveTo(const Offset(10, 60));
    await gesture.up();
    await tester.pump();
    expect(
      [
        for (final event in connection.pointers)
          (event.phase.name, event.device.name),
      ],
      [
        ('POINTER_PHASE_DOWN', 'POINTER_DEVICE_TOUCH'),
        ('POINTER_PHASE_MOVE', 'POINTER_DEVICE_TOUCH'),
        ('POINTER_PHASE_UP', 'POINTER_DEVICE_TOUCH'),
        ('POINTER_PHASE_REMOVE', 'POINTER_DEVICE_TOUCH'),
      ],
    );
    await gesture.removePointer();
  });

  testWidgets('with touch, Option puts down a second finger across the '
      'center', (tester) async {
    // #208: as iOS Simulator has it, so a mouse can pinch.
    final connection = _FakeConnection();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 100,
            height: 50,
            child: RaccoonView(
              connection: connection,
              pixelRatio: 1,
              touch: true,
            ),
          ),
        ),
      ),
    );
    final origin = tester.getTopLeft(find.byType(RaccoonView));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: origin + const Offset(10, 10));
    await gesture.down(origin + const Offset(10, 10));
    await gesture.moveTo(origin + const Offset(20, 10));
    await gesture.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    final first = connection.pointers.first.pointerId;
    expect(
      [
        for (final event in connection.pointers)
          (
            event.phase.name.replaceFirst('POINTER_PHASE_', ''),
            event.pointerId - first,
            event.x,
            event.y,
          ),
      ],
      [
        ('DOWN', 0, 10.0, 10.0),
        ('DOWN', 1 << 20, 90.0, 40.0),
        ('MOVE', 0, 20.0, 10.0),
        ('MOVE', 1 << 20, 80.0, 40.0),
        ('UP', 0, 20.0, 10.0),
        ('REMOVE', 0, 20.0, 10.0),
        ('UP', 1 << 20, 80.0, 40.0),
        ('REMOVE', 1 << 20, 80.0, 40.0),
      ],
    );
    await gesture.removePointer();
  });

  testWidgets('touch turned off mid-press lifts the finger it left down', (
    tester,
  ) async {
    // #213: it stayed down in the app, every later tap a second finger.
    final connection = _FakeConnection();
    Widget view(bool touch) =>
        RaccoonView(connection: connection, pixelRatio: 1, touch: touch);
    await tester.pumpWidget(view(true));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(10, 10));
    await gesture.down(const Offset(10, 10));
    await tester.pump();
    final finger = connection.pointers.last.pointerId;
    await tester.pumpWidget(view(false));
    expect(
      [
        for (final event in connection.pointers.skip(1))
          (event.phase.name, event.pointerId == finger),
      ],
      [('POINTER_PHASE_CANCEL', true), ('POINTER_PHASE_REMOVE', true)],
    );
    await gesture.up();
    await gesture.removePointer();
  });
}

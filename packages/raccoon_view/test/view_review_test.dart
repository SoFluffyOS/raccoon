// Findings of a review of the view, each failing before its fix (#232).
import 'dart:async';

import 'package:fixnum/fixnum.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raccoon/raccoon.dart' as rc;
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:raccoon_view/raccoon_view.dart';

class _Conn
    implements
        RunnerConnection,
        GpuBufferConnection,
        CaptureConnection,
        ComposingConnection {
  _Conn({this.gpu = false, this.composing = false});
  final bool gpu;
  final bool composing;
  final frameController = StreamController<rc.Frame>.broadcast();
  final sets = StreamController<rc.GpuBuffers>.broadcast();
  final fields = StreamController<rc.TextField>.broadcast();
  final released = <(int, int)>[];
  final pointers = <rc.PointerEvent>[];
  final keys = <rc.KeyEvent>[];
  final editings = <rc.TextEditing>[];
  final asked = <bool>[];

  @override
  bool get gpuBuffers => gpu;
  @override
  bool get composes => composing;
  @override
  Stream<rc.Frame> get frames => frameController.stream;
  @override
  Stream<rc.GpuBuffers> get gpuBufferSets => sets.stream;
  @override
  rc.GpuBuffers? get latestGpuBuffers => null;
  @override
  Stream<rc.TextField> get textFields => fields.stream;
  @override
  rc.TextField? get latestTextField => null;
  @override
  void releaseGpuBuffer(int generation, int index) =>
      released.add((generation, index));
  @override
  void resize(int width, int height, double pixelRatio) {}
  @override
  void sendPointer(rc.PointerEvent event) => pointers.add(event);
  @override
  void sendKey(rc.KeyEvent event) => keys.add(event);
  @override
  void sendTextEditing(rc.TextEditing editing) => editings.add(editing);
  @override
  bool get pixelsWanted =>
      asked.where((on) => on).length > asked.where((on) => !on).length;
  @override
  void wantPixels(bool on) => asked.add(on);
}

class _Textures implements HostGpuTextures {
  _Textures({
    this.releases = false,
    this.gateShow = false,
    this.gateConnect = false,
  });
  final bool releases;
  final bool gateShow;
  final bool gateConnect;
  var nextId = 1;
  final calls = <String>[];
  final shows = <Completer<void>>[];
  final connects = <Completer<bool>>[];

  @override
  bool get bottomUp => false;

  @override
  Future<int> create() async {
    final id = nextId++;
    calls.add('create $id');
    return id;
  }

  @override
  Future<bool> connect(int textureId, String socket) {
    calls.add('connect $textureId');
    if (!gateConnect) return Future.value(releases);
    final c = Completer<bool>();
    connects.add(c);
    return c.future;
  }

  @override
  Future<void> show(int textureId, int generation, int index) {
    calls.add('show $textureId $generation/$index');
    if (!gateShow) return Future.value();
    final c = Completer<void>();
    shows.add(c);
    return c.future;
  }

  @override
  Future<void> dispose(int textureId) async => calls.add('dispose $textureId');
}

rc.GpuBuffers _set() => rc.GpuBuffers(
  generation: 1,
  count: 3,
  width: 8,
  height: 8,
  socket: '/run/r.gpu',
);

rc.Frame _gpuFrame(int index) => rc.Frame(
  sequence: Int64(index + 1),
  inGpuBuffer: true,
  bufferIndex: index,
  gpuGeneration: 1,
);

class _ChannelConnection implements RunnerConnection, ChannelConnection {
  final channels = <String, PlatformChannelHandler>{};
  @override
  Stream<rc.Frame> get frames => const Stream.empty();
  @override
  void resize(int width, int height, double pixelRatio) {}
  @override
  void sendPointer(rc.PointerEvent event) {}
  @override
  void sendKey(rc.KeyEvent event) {}
  @override
  void registerChannel(String channel, PlatformChannelHandler handler) =>
      channels[channel] = handler;
  @override
  void unregisterChannel(String channel) => channels.remove(channel);
}

void main() {
  // #232: a show still under way when the view went read the cleared
  // flag, and gave back a buffer the host gives back itself.
  testWidgets('a buffer the host gives back is not given back by a show '
      'that ends after the view went', (tester) async {
    final connection = _Conn(gpu: true);
    final textures = _Textures(releases: true, gateShow: true);
    await tester.pumpWidget(
      RaccoonView(connection: connection, gpuTextures: textures),
    );
    connection.sets.add(_set());
    await tester.pump();
    connection.frameController.add(_gpuFrame(0));
    await tester.pump();
    textures.shows.removeAt(0).complete();
    await tester.pump();
    connection.frameController.add(_gpuFrame(1));
    await tester.pump();
    // show of 1/1 in flight; the view goes.
    await tester.pumpWidget(const SizedBox());
    textures.shows.removeAt(0).complete();
    await tester.pump();
    // The host gives buffers back itself; the view must release nothing.
    expect(connection.released, isEmpty);
  });

  // #232: a swap cleared the held keys without telling the old runner.
  testWidgets('keys held on the old connection go up on a swap', (
    tester,
  ) async {
    final a = _Conn();
    final b = _Conn();
    await tester.pumpWidget(RaccoonView(connection: a));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    expect(a.keys.single.kind, rc.KeyKind.KEY_KIND_DOWN);
    await tester.pumpWidget(RaccoonView(connection: b));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    expect(
      a.keys.where((k) => k.kind == rc.KeyKind.KEY_KIND_UP),
      isNotEmpty,
      reason: 'old runner never hears Meta go up',
    );
  });

  // #232: a holder that went while its texture was still connecting
  // handed the ring on at once, and the next view's texture connected
  // while the first still held the GPU socket, which takes one at a time.
  testWidgets('the ring waits for a texture still connecting to let go', (
    tester,
  ) async {
    final connection = _Conn(gpu: true);
    final textures = _Textures(gateConnect: true);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Row(
          children: [
            Expanded(
              child: RaccoonView(
                key: const ValueKey('a'),
                connection: connection,
                gpuTextures: textures,
              ),
            ),
            Expanded(
              child: RaccoonView(
                key: const ValueKey('b'),
                connection: connection,
                gpuTextures: textures,
              ),
            ),
          ],
        ),
      ),
    );
    connection.sets.add(_set());
    await tester.pump();
    expect(textures.calls, ['create 1', 'connect 1']);
    // A goes while its connect is in flight.
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Row(
          children: [
            Expanded(
              child: RaccoonView(
                key: const ValueKey('b'),
                connection: connection,
                gpuTextures: textures,
              ),
            ),
          ],
        ),
      ),
    );
    connection.sets.add(_set());
    await tester.pump();
    expect(textures.calls, ['create 1', 'connect 1']);
    textures.connects[0].complete(false);
    await tester.pump();
    expect(textures.calls, ['create 1', 'connect 1', 'dispose 1']);
    connection.sets.add(_set());
    await tester.pump();
    expect(textures.calls, [
      'create 1',
      'connect 1',
      'dispose 1',
      'create 2',
      'connect 2',
    ]);
  });

  testWidgets('the host input method lets go when the runner is lost', (
    tester,
  ) async {
    final connection = _Conn(composing: true);
    await tester.pumpWidget(RaccoonView(connection: connection));
    connection.fields.add(
      rc.TextField(active: true, inputAction: 'TextInputAction.done'),
    );
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isTrue);
    await connection.frameController.close();
    await connection.fields.close();
    await tester.pump();
    expect(find.text('Runner disconnected'), findsOneWidget);
    expect(
      tester.testTextInput.hasAnyClients,
      isFalse,
      reason: 'IME still attached to a dead runner',
    );
  });

  // #232: the board panned under the app as the app scrolled.
  testWidgets('a wheel over an app on the board scrolls the app only', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(2400, 1600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final connection = _Conn();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RaccoonBoard(
          sessions: [
            RaccoonBoardSession(name: 'counter', connection: connection),
          ],
          layout: RaccoonBoardLayout(),
        ),
      ),
    );
    final before = tester.getTopLeft(find.byType(RaccoonView));
    final center = tester.getCenter(find.byType(RaccoonView));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(center));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
    await tester.pump();
    final scrolls = connection.pointers.where((p) => p.scrollDeltaY != 0);
    expect(scrolls, isNotEmpty, reason: 'app got the wheel');
    expect(
      tester.getTopLeft(find.byType(RaccoonView)),
      before,
      reason: 'board panned under the app too',
    );
  });

  // #232: each view registered the connection's cursor channel, and
  // either one going unregistered it for both.
  testWidgets('the cursor channel stays while a view of the connection does', (
    tester,
  ) async {
    final connection = _ChannelConnection();
    Widget views(bool both) => Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        children: [
          Expanded(
            child: RaccoonView(
              key: const ValueKey('a'),
              connection: connection,
            ),
          ),
          if (both)
            Expanded(
              child: RaccoonView(
                key: const ValueKey('b'),
                connection: connection,
              ),
            ),
        ],
      ),
    );
    await tester.pumpWidget(views(true));
    await tester.pumpWidget(views(false));
    expect(
      connection.channels,
      contains('flutter/mousecursor'),
      reason: 'view a still shows the app but its cursor channel is gone',
    );
  });
}

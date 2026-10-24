import 'dart:async';

import 'package:fixnum/fixnum.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raccoon/raccoon.dart' as rc;
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:raccoon_view/raccoon_view.dart';

class _GpuConnection implements RunnerConnection, GpuBufferConnection {
  final frameController = StreamController<rc.Frame>.broadcast();
  final sets = StreamController<rc.GpuBuffers>.broadcast();
  final released = <(int, int)>[];

  @override
  bool get gpuBuffers => true;

  @override
  Stream<rc.Frame> get frames => frameController.stream;

  @override
  Stream<rc.GpuBuffers> get gpuBufferSets => sets.stream;

  @override
  rc.GpuBuffers? get latestGpuBuffers => null;

  @override
  void releaseGpuBuffer(int generation, int index) =>
      released.add((generation, index));

  @override
  void resize(int width, int height, double pixelRatio) {}

  @override
  void sendPointer(rc.PointerEvent event) {}

  @override
  void sendKey(rc.KeyEvent event) {}
}

class _FakeTextures implements HostGpuTextures {
  _FakeTextures({this.releases = false, this.bottomUp = true});

  /// Whether this host gives buffers back to the runner itself.
  final bool releases;

  @override
  final bool bottomUp;

  final calls = <String>[];

  @override
  Future<int> create() async {
    calls.add('create');
    return 7;
  }

  @override
  Future<bool> connect(int textureId, String socket) async {
    calls.add('connect $textureId $socket');
    return releases;
  }

  @override
  Future<void> show(int textureId, int generation, int index) async =>
      calls.add('show $textureId $generation/$index');

  @override
  Future<void> dispose(int textureId) async => calls.add('dispose $textureId');
}

/// Textures whose creation waits for the test, each with an id of its own;
/// a create may fail.
class _GatedTextures extends _FakeTextures {
  final pending = <Completer<int>>[];
  var nextId = 1;

  @override
  Future<int> create() {
    calls.add('create');
    final made = Completer<int>();
    pending.add(made);
    return made.future;
  }
}

rc.GpuBuffers _set(String socket) => rc.GpuBuffers(
  generation: 1,
  count: 3,
  width: 800,
  height: 600,
  socket: socket,
);

/// The transform the texture is drawn through.
Matrix4 _flipOf(WidgetTester tester) =>
    tester
        .widget<Transform>(
          find
              .ancestor(
                of: find.byType(Texture),
                matching: find.byType(Transform),
              )
              .first,
        )
        .transform;

void main() {
  testWidgets(
    'GPU buffer frames show through the host texture and are given back',
    (tester) async {
      final connection = _GpuConnection();
      final textures = _FakeTextures();
      await tester.pumpWidget(
        RaccoonView(connection: connection, gpuTextures: textures),
      );
      expect(find.byType(Texture), findsNothing);

      connection.sets.add(
        rc.GpuBuffers(
          generation: 1,
          count: 3,
          width: 800,
          height: 600,
          socket: '/run/r.gpu',
        ),
      );
      await tester.pump();
      expect(textures.calls, ['create', 'connect 7 /run/r.gpu']);

      connection.frameController.add(
        rc.Frame(
          sequence: Int64(1),
          inGpuBuffer: true,
          bufferIndex: 0,
          gpuGeneration: 1,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(textures.calls.last, 'show 7 1/0');
      expect(connection.released, isEmpty);
      expect(find.byType(Texture), findsOneWidget);
      expect(tester.widget<Texture>(find.byType(Texture)).textureId, 7);
      // A GL texture starts at the bottom: drawn the other way up.
      expect(_flipOf(tester), Matrix4.diagonal3Values(1, -1, 1));

      connection.frameController.add(
        rc.Frame(
          sequence: Int64(2),
          inGpuBuffer: true,
          bufferIndex: 1,
          gpuGeneration: 1,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(textures.calls.last, 'show 7 1/1');
      expect(connection.released, [(1, 0)]);

      await tester.pumpWidget(const SizedBox());
      expect(connection.released, [(1, 0), (1, 1)]);
      expect(textures.calls.last, 'dispose 7');
    },
  );

  testWidgets('pixel frames are dropped while the texture is live', (
    tester,
  ) async {
    final connection = _GpuConnection();
    final textures = _FakeTextures(releases: true);
    await tester.pumpWidget(
      RaccoonView(connection: connection, gpuTextures: textures),
    );
    connection.sets.add(
      rc.GpuBuffers(
        generation: 1,
        count: 3,
        width: 8,
        height: 8,
        socket: '/run/r.gpu',
      ),
    );
    await tester.pump();
    connection.frameController.add(
      rc.Frame(
        sequence: Int64(1),
        inGpuBuffer: true,
        bufferIndex: 0,
        gpuGeneration: 1,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(Texture), findsOneWidget);

    // A readback frame right after: the texture stays, nothing is decoded.
    connection.frameController.add(
      rc.Frame(
        sequence: Int64(2),
        width: 8,
        height: 8,
        rowBytes: 32,
        format: rc.PixelFormat.PIXEL_FORMAT_BGRA8888,
        pixels: List.filled(8 * 8 * 4, 0),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(Texture), findsOneWidget);
    expect(find.byType(RaccoonFrameView), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a frame that came before the texture shows once it is there', (
    tester,
  ) async {
    // A still app sends one frame, and it may land before the set names
    // the socket: the view keeps the latest such frame and names it to the
    // host once connected, giving back any earlier one it kept.
    final connection = _GpuConnection();
    final textures = _FakeTextures(releases: true);
    await tester.pumpWidget(
      RaccoonView(connection: connection, gpuTextures: textures),
    );
    for (final index in [0, 1]) {
      connection.frameController.add(
        rc.Frame(
          sequence: Int64(index + 1),
          inGpuBuffer: true,
          bufferIndex: index,
          gpuGeneration: 1,
        ),
      );
      await tester.pump();
    }
    expect(textures.calls, isEmpty);
    expect(connection.released, [(1, 0)]);

    connection.sets.add(
      rc.GpuBuffers(
        generation: 1,
        count: 3,
        width: 8,
        height: 8,
        socket: '/run/r.gpu',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(textures.calls, ['create', 'connect 7 /run/r.gpu', 'show 7 1/1']);
    expect(find.byType(Texture), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    expect(connection.released, [(1, 0)]);
  });

  testWidgets('a texture that starts at the top is drawn as it is', (
    tester,
  ) async {
    final connection = _GpuConnection();
    final textures = _FakeTextures(releases: true, bottomUp: false);
    await tester.pumpWidget(
      RaccoonView(connection: connection, gpuTextures: textures),
    );
    connection.sets.add(
      rc.GpuBuffers(
        generation: 1,
        count: 3,
        width: 8,
        height: 8,
        socket: '/run/r.gpu',
      ),
    );
    await tester.pump();
    connection.frameController.add(
      rc.Frame(
        sequence: Int64(1),
        inGpuBuffer: true,
        bufferIndex: 0,
        gpuGeneration: 1,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(Texture), findsOneWidget);
    expect(_flipOf(tester), Matrix4.identity());

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a host that gives buffers back itself is left to it', (
    tester,
  ) async {
    final connection = _GpuConnection();
    final textures = _FakeTextures(releases: true);
    await tester.pumpWidget(
      RaccoonView(connection: connection, gpuTextures: textures),
    );
    connection.sets.add(
      rc.GpuBuffers(
        generation: 1,
        count: 3,
        width: 800,
        height: 600,
        socket: '/run/r.gpu',
      ),
    );
    await tester.pump();
    for (final index in [0, 1, 2]) {
      connection.frameController.add(
        rc.Frame(
          sequence: Int64(index + 1),
          inGpuBuffer: true,
          bufferIndex: index,
          gpuGeneration: 1,
        ),
      );
      await tester.pump();
      await tester.pump();
    }
    expect(textures.calls.last, 'show 7 1/2');
    expect(connection.released, isEmpty);

    await tester.pumpWidget(const SizedBox());
    expect(connection.released, isEmpty);
    expect(textures.calls.last, 'dispose 7');
  });

  // #133: a texture made for the connection before was taken for the new
  // one, and the loser leaked.
  testWidgets('a texture made for a connection since swapped is let go', (
    tester,
  ) async {
    final first = _GpuConnection();
    final second = _GpuConnection();
    final textures = _GatedTextures();
    await tester.pumpWidget(
      RaccoonView(connection: first, gpuTextures: textures),
    );
    first.sets.add(_set('/run/first.gpu'));
    await tester.pump();
    await tester.pumpWidget(
      RaccoonView(connection: second, gpuTextures: textures),
    );
    second.sets.add(_set('/run/second.gpu'));
    await tester.pump();
    expect(textures.pending, hasLength(2));

    textures.pending[0].complete(1);
    await tester.pump();
    textures.pending[1].complete(2);
    await tester.pump();
    await tester.pump();
    expect(textures.calls, [
      'create',
      'create',
      'dispose 1',
      'connect 2 /run/second.gpu',
    ]);

    await tester.pumpWidget(const SizedBox());
    expect(textures.calls.last, 'dispose 2');
  });

  testWidgets('a texture that fails to be made is tried again', (tester) async {
    final connection = _GpuConnection();
    final textures = _GatedTextures();
    await tester.pumpWidget(
      RaccoonView(connection: connection, gpuTextures: textures),
    );
    connection.sets.add(_set('/run/r.gpu'));
    await tester.pump();
    textures.pending[0].completeError(StateError('no texture'));
    await tester.pump();

    connection.sets.add(_set('/run/r.gpu'));
    await tester.pump();
    expect(textures.pending, hasLength(2));
    textures.pending[1].complete(3);
    await tester.pump();
    await tester.pump();
    expect(textures.calls.last, 'connect 3 /run/r.gpu');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the buffer on screen, sent again, is not given back', (
    tester,
  ) async {
    final connection = _GpuConnection();
    final textures = _FakeTextures();
    await tester.pumpWidget(
      RaccoonView(connection: connection, gpuTextures: textures),
    );
    connection.sets.add(_set('/run/r.gpu'));
    await tester.pump();
    rc.Frame inBuffer(int sequence, int index) => rc.Frame(
      sequence: Int64(sequence),
      inGpuBuffer: true,
      bufferIndex: index,
      gpuGeneration: 1,
    );
    // The last frame, replayed to a view made anew, then the same buffer
    // handed out again for the app's next frame.
    for (final frame in [inBuffer(1, 0), inBuffer(2, 0), inBuffer(3, 1)]) {
      connection.frameController.add(frame);
      await tester.pump();
      await tester.pump();
    }
    expect(connection.released, [(1, 0)]);
    await tester.pumpWidget(const SizedBox());
  });

  // #143: on a swap, the old runner's buffers went back to the new one,
  // which could free the buffer it showed.
  testWidgets('a swap gives the old runner back its own buffers', (
    tester,
  ) async {
    final first = _GpuConnection();
    final second = _GpuConnection();
    final textures = _FakeTextures();
    await tester.pumpWidget(
      RaccoonView(connection: first, gpuTextures: textures),
    );
    first.sets.add(_set('/run/first.gpu'));
    await tester.pump();
    first.frameController.add(
      rc.Frame(
        sequence: Int64(1),
        inGpuBuffer: true,
        bufferIndex: 0,
        gpuGeneration: 1,
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.pumpWidget(
      RaccoonView(connection: second, gpuTextures: textures),
    );
    expect(first.released, [(1, 0)]);
    expect(second.released, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  // #143: a quiet ring was given up before the pixel frame decoded, and a
  // frame that failed left the view on stale content.
  testWidgets('the texture stays until a pixel frame has taken its place', (
    tester,
  ) async {
    final connection = _GpuConnection();
    final textures = _FakeTextures();
    await tester.pumpWidget(
      RaccoonView(connection: connection, gpuTextures: textures),
    );
    connection.sets.add(_set('/run/r.gpu'));
    await tester.pump();
    connection.frameController.add(
      rc.Frame(
        sequence: Int64(1),
        inGpuBuffer: true,
        bufferIndex: 0,
        gpuGeneration: 1,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(Texture), findsOneWidget);

    // The ring goes quiet; a pixel frame that can't be decoded comes.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 600)),
    );
    connection.frameController.add(
      rc.Frame(
        sequence: Int64(2),
        width: 4,
        height: 4,
        rowBytes: 16,
        format: rc.PixelFormat.PIXEL_FORMAT_BGRA8888,
        pixels: List.filled(8, 0),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(find.byType(Texture), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}

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
  _FakeTextures({this.releases = false});

  /// Whether this host gives buffers back to the runner itself.
  final bool releases;
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
}

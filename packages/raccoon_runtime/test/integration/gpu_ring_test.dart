// Drives the real runner: a client's GPU ring, its buffers and captures, the
// GPU socket, Mach ports, shared handles and dmabufs, and the views' pace
// beside a held ring. Tagged timing: a test held up for four frames before it
// listens leaves those frames unreleased and the ring starved, and the pace
// tests count frames a second, so CI runs these after the rest, one file at a
// time (#383, #413). Skipped when the runner or its inputs are not built; see
// native/raccoon_runner/tool/render_example.sh. What the files share is in
// test/support/runner_fixture.dart.

@Tags(['timing'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:path/path.dart' as p;
import 'package:raccoon/raccoon.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

import '../support/runner_fixture.dart';

// The fixture's helpers, by the names these tests have always used.
const _expectExit = expectExit;
const _exitCode = runnerExitCode;

void main() {
  final RunnerFixture(
    :binary,
    :assets,
    :engineDir,
    :icu,
    :ready,
    :viewsAssets,
  ) = RunnerFixture();
  test(
    'a view takes GPU buffers of its own, served on a GPU socket of its own',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_views');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: viewsAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          views: true,
        ),
      );
      final first = await RunnerClient.connect(endpoint, gpuBuffers: true);
      final view = await RunnerClient.connect(endpoint.views, gpuBuffers: true);
      try {
        await view.hello.timeout(const Duration(seconds: 10));
        // A frame in a GPU buffer is not replayed: listened for first.
        final gpuFrame = view.frames.firstWhere((f) => f.inGpuBuffer);
        gpuFrame.ignore();
        view.resize(320, 240, 2);
        final GpuBuffers set;
        try {
          set = await view.gpuBufferSets.first.timeout(
            const Duration(seconds: 5),
          );
        } on TimeoutException {
          printOnFailure('no GPU buffers offered: ${view.latestGpuBuffers}');
          return;
        }
        expect((set.width, set.height), (320, 240));
        expect(set.socket, p.join(temp.path, 'runner.v1.gpu'));
        expect(File(set.socket).existsSync() || Platform.isWindows, isTrue);
        final frame = await gpuFrame.timeout(const Duration(seconds: 10));
        expect(frame.gpuGeneration, set.generation);
        view.releaseGpuBuffer(frame.gpuGeneration, frame.bufferIndex);

        // The first view's ring is its own, at its own size.
        final own = await first.gpuBufferSets.first.timeout(
          const Duration(seconds: 10),
        );
        expect((own.width, own.height), (800, 600));
        expect(own.socket, p.join(temp.path, 'runner.gpu'));

        // A new size is a new ring.
        view.resize(400, 300, 2);
        final grown = await view.gpuBufferSets
            .firstWhere((s) => s.width == 400)
            .timeout(const Duration(seconds: 10));
        expect(grown.generation, greaterThan(set.generation));
      } finally {
        await view.close();
        first.shutdown();
        await first.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(viewsAssets).existsSync()
            ? false
            : 'build the runner and example/views first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  // #153: a hello again without GPU buffers left the ring in use, and the
  // client got no frames at all.
  test(
    'a hello without GPU buffers turns the runner back to pixel frames',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final socket = await RawSocket.connect(
        InternetAddress(endpoint.path, type: InternetAddressType.unix),
        0,
      );
      final unframer = MessageUnframer();
      final messages = StreamController<RunnerMessage>.broadcast();
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        // No shared buffers asked for, so no descriptors come: a plain
        // read, which Windows has too.
        final data = socket.read();
        if (data == null) return;
        for (final payload in unframer.add(data)) {
          messages.add(RunnerMessage.fromBuffer(payload));
        }
      });
      void send(ClientMessage message) =>
          socket.write(MessageFraming.frame(message.writeToBuffer()));
      try {
        // The first frame may come inline, before the hello is read.
        final first = messages.stream
            .firstWhere((m) => m.hasFrame() && m.frame.inGpuBuffer)
            .then<RunnerMessage?>((m) => m)
            .timeout(const Duration(seconds: 15), onTimeout: () => null);
        send(
          ClientMessage(
            hello: ClientHello(protocolVersion: 1, pid: 1, gpuBuffers: true),
          ),
        );
        // Without a GPU (a CI machine) there is no ring to leave.
        if (await first == null) {
          send(ClientMessage(shutdown: Shutdown()));
          expect(await _exitCode(runner), 0);
          return;
        }

        final inline = messages.stream.firstWhere(
          (m) => m.hasFrame() && !m.frame.inGpuBuffer,
        );
        send(ClientMessage(hello: ClientHello(protocolVersion: 1, pid: 1)));
        final frame = (await inline.timeout(const Duration(seconds: 5))).frame;
        expect(frame.pixels, isNotEmpty);
        send(ClientMessage(shutdown: Shutdown()));
        expect(await _exitCode(runner), 0);
      } finally {
        await socket.close();
        await messages.close();
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );
  // #138: after a client that took frames as GPU buffers, the latest frame
  // was in one, and a client that came next to an idle app got none until
  // it sent its size.
  test(
    'a client after a GPU buffer client gets a frame of its own',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      try {
        final gpu = await RunnerClient.connect(endpoint, gpuBuffers: true);
        await gpu.frames.first.timeout(const Duration(seconds: 15));
        await gpu.close();
        await Future<void>.delayed(const Duration(milliseconds: 300));

        // No resize: an idle app draws nothing for it unless the runner does.
        final next = await RunnerClient.connect(endpoint);
        final frame = await next.frames.first.timeout(
          const Duration(seconds: 5),
        );
        expect(frame.inGpuBuffer, isFalse);
        expect(frame.pixels, isNotEmpty);
        next.shutdown();
        await next.close();
        expect(await _exitCode(runner), 0);
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );
  // #153: a frame that went by readback for want of a ring buffer was the
  // last an idle app drew, and a client drawing the ring drops it.
  test(
    'a GPU client takes pixel frames while it wants them, then buffers again',
    () async {
      // #202: a capture reads pixels; a GPU buffer frame has none.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint, gpuBuffers: true);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        final first = await client.frames
            .firstWhere((frame) => frame.inGpuBuffer)
            .then<Frame?>((frame) => frame)
            .timeout(const Duration(seconds: 15), onTimeout: () => null);
        // Without a GPU (a CI machine) every frame has pixels already.
        if (first == null) {
          printOnFailure('no GPU ring on this host');
          return;
        }
        client.releaseGpuBuffer(first.gpuGeneration, first.bufferIndex);
        // Two captures at once: pixels until both are done.
        client
          ..wantPixels(true)
          ..wantPixels(true);
        final pixels = await client.frames
            .firstWhere((frame) => !frame.inGpuBuffer)
            .timeout(const Duration(seconds: 15));
        expect(pixels.pixels, isNotEmpty);
        client.wantPixels(false);
        // One is still capturing: no ring yet. A redraw shows which.
        client.resize(810, 600, 1);
        final still = await client.frames.first.timeout(
          const Duration(seconds: 15),
        );
        expect(still.inGpuBuffer, isFalse);
        client.wantPixels(false);
        final again = await client.frames
            .firstWhere((frame) => frame.inGpuBuffer)
            .timeout(const Duration(seconds: 15));
        expect(again.inGpuBuffer, isTrue);
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  // #400: a capture turns the ring off and on again. On GL the pool was
  // destroyed and built again, a new set for the host to import at every
  // screenshot, and the frame after went by readback.
  test(
    'a capture on a GPU client keeps its ring, and the frame after goes in it',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint, gpuBuffers: true);
      final sets = <int>{};
      final watching = client.gpuBufferSets.listen(
        (set) => sets.add(set.generation),
      );
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        final first = await client.frames
            .firstWhere((frame) => frame.inGpuBuffer)
            .then<Frame?>((frame) => frame)
            .timeout(const Duration(seconds: 15), onTimeout: () => null);
        // Without a GPU (a CI machine) every frame has pixels already.
        if (first == null) {
          printOnFailure('no GPU ring on this host');
          return;
        }
        client.releaseGpuBuffer(first.gpuGeneration, first.bufferIndex);
        // The app's first frames drawn: nothing else on its way.
        final settling = client.frames.listen((frame) {
          if (frame.inGpuBuffer) {
            client.releaseGpuBuffer(frame.gpuGeneration, frame.bufferIndex);
          }
        });
        await Future<void>.delayed(const Duration(seconds: 1));
        await settling.cancel();
        for (var capture = 0; capture < 2; capture++) {
          client.wantPixels(true);
          final pixels = await client.frames
              .firstWhere((frame) => !frame.inGpuBuffer)
              .timeout(const Duration(seconds: 15));
          expect(pixels.pixels, isNotEmpty);
          client.wantPixels(false);
          // The frames stream starts with the latest: the capture's.
          final after = await client.frames
              .firstWhere((frame) => frame.sequence > pixels.sequence)
              .timeout(const Duration(seconds: 15));
          expect(after.inGpuBuffer, isTrue, reason: 'capture $capture');
          expect(after.gpuGeneration, first.gpuGeneration);
          client.releaseGpuBuffer(after.gpuGeneration, after.bufferIndex);
        }
        expect(sets, {first.gpuGeneration});
      } finally {
        await watching.cancel();
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    // Metal and Vulkan still build a new pool after a capture.
    skip: switch ((ready, Platform.isLinux)) {
      (false, _) => 'build the runner and example first',
      (_, false) => 'the GL renderer keeps its ring (#400)',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'a GPU client gets the frame it missed once it gives a buffer back',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint, gpuBuffers: true);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        // Every buffer stays with the client, so the ring runs dry.
        final held = <Frame>[];
        final readback = Completer<void>();
        final afterRelease = Completer<Frame>();
        var released = false;
        final frames = client.frames.listen((frame) {
          if (frame.inGpuBuffer) {
            if (released && !afterRelease.isCompleted) {
              afterRelease.complete(frame);
            }
            held.add(frame);
          } else if (!readback.isCompleted) {
            readback.complete();
          }
        });
        // The first frame may come inline, before the hello is read.
        final first = await client.frames
            .firstWhere((frame) => frame.inGpuBuffer)
            .then<Frame?>((frame) => frame)
            .timeout(const Duration(seconds: 15), onTimeout: () => null);
        // Without a GPU (a CI machine) the runner has no ring to run dry.
        if (first == null) {
          await frames.cancel();
          printOnFailure('no GPU ring on this host');
          return;
        }
        Future<void> tap() async {
          for (final (phase, buttons) in [
            (PointerPhase.POINTER_PHASE_DOWN, 1),
            (PointerPhase.POINTER_PHASE_UP, 0),
          ]) {
            client.sendPointer(
              PointerEvent(
                phase: phase,
                x: 400,
                y: 300,
                buttons: Int64(buttons),
                device: PointerDevice.POINTER_DEVICE_MOUSE,
                pointerId: 1,
              ),
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }

        for (var i = 0; i < 8 && !readback.isCompleted; i++) {
          await tap();
        }
        await readback.future.timeout(const Duration(seconds: 5));
        // The app is idle now; its last frame went by readback.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        released = true;
        for (final frame in held.toList()) {
          client.releaseGpuBuffer(frame.gpuGeneration, frame.bufferIndex);
        }
        final again = await afterRelease.future.timeout(
          const Duration(seconds: 3),
        );
        expect(again.inGpuBuffer, isTrue);
        await frames.cancel();
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );
  // #397: on GL the hello's own frame was drawn into the framebuffer taken
  // a frame before, the readback target, and the pool was built after it:
  // an idle app left a client that said hello late with nothing in its
  // ring.
  test(
    'a GPU client that says hello to an idle app gets a frame in its ring',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
          headless: true,
        ),
      );
      final firstFrame = runner.stderr.firstWhere(
        (line) => line.contains('first frame'),
      );
      firstFrame.ignore();
      RunnerClient? client;
      try {
        // Frames by readback, then nothing: the app is idle.
        if (!runner.lastLines.any((line) => line.contains('first frame'))) {
          await firstFrame.timeout(const Duration(seconds: 15));
        }
        await Future<void>.delayed(const Duration(seconds: 1));
        client = await RunnerClient.connect(endpoint, gpuBuffers: true);
        final gpuFrame = client.frames.firstWhere((frame) => frame.inGpuBuffer);
        gpuFrame.ignore();
        await client.hello.timeout(const Duration(seconds: 10));
        final set = await client.gpuBufferSets.first
            .then<GpuBuffers?>((set) => set)
            .timeout(const Duration(seconds: 10), onTimeout: () => null);
        // Without a GPU (a CI machine) there is no ring to fill.
        if (set == null) {
          printOnFailure('no GPU ring on this host');
          return;
        }
        final frame = await gpuFrame.timeout(
          const Duration(seconds: 5),
          onTimeout:
              () =>
                  throw TestFailure(
                    'no frame in the ring; the runner said:\n  '
                    '${runner.lastLines.join('\n  ')}',
                  ),
        );
        expect(frame.gpuGeneration, set.generation);
        client.releaseGpuBuffer(frame.gpuGeneration, frame.bufferIndex);
      } finally {
        client?.shutdown();
        await client?.close();
        if (client == null) runner.kill();
        await _exitCode(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );
  // #123: on GL the engine takes the next frame's framebuffer as it
  // presents a frame. Its ring buffer was chosen then, so a vsync that
  // asked for a free one looked a frame ahead: with the client holding all
  // but one, the next frame waited the whole hold for a buffer it had.
  test(
    'a GPU client holding all but one buffer gets the next frame without the ring\'s hold',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint, gpuBuffers: true);
      try {
        // Every buffer the client is sent stays with it.
        final held = <Frame>[];
        Completer<void>? next;
        final frames = client.frames.listen((frame) {
          if (!frame.inGpuBuffer) return;
          held.add(frame);
          next?.complete();
          next = null;
        });
        await client.hello.timeout(const Duration(seconds: 10));
        final ring = await client.gpuBufferSets.first
            .then<GpuBuffers?>((set) => set)
            .timeout(const Duration(seconds: 15), onTimeout: () => null);
        // Without a GPU (a CI machine) there is no ring to hold.
        if (ring == null) {
          await frames.cancel();
          printOnFailure('no GPU ring on this host');
          return;
        }
        // One frame a tap: the box changes colour.
        Future<Duration> tap() async {
          final arrived = next = Completer<void>();
          final clock = Stopwatch()..start();
          for (final (phase, buttons) in [
            (PointerPhase.POINTER_PHASE_DOWN, 1),
            (PointerPhase.POINTER_PHASE_UP, 0),
          ]) {
            client.sendPointer(
              PointerEvent(
                phase: phase,
                x: 400,
                y: 300,
                buttons: Int64(buttons),
                device: PointerDevice.POINTER_DEVICE_MOUSE,
                pointerId: 1,
              ),
            );
          }
          await arrived.future.timeout(const Duration(seconds: 5));
          final took = clock.elapsed;
          // Nothing else in flight before the next tap.
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return took;
        }

        while (held.length < ring.count - 1) {
          await tap();
        }
        // All but one buffer held: the last one is free for this frame.
        final took = await tap();
        expect(held, hasLength(ring.count));
        expect(
          held.map((frame) => frame.bufferIndex).toSet(),
          hasLength(ring.count),
        );
        // The ring's hold is 100 ms.
        expect(took, lessThan(const Duration(milliseconds: 90)));
        await frames.cancel();
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'a view that comes back to a running app gets GPU frames again',
    () async {
      // A tab hidden: its view goes with its GPU socket, and the frames the
      // app draws meanwhile fill the ring with no one to give them back.
      // The view that comes back must not find the ring full, every frame
      // then going by readback at ten a second.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final spinAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'spin',
        'build',
        'flutter_assets',
      );
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: spinAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint, gpuBuffers: true);
      try {
        final first = await client.frames
            .firstWhere((frame) => frame.inGpuBuffer)
            .then<Frame?>((frame) => frame)
            .timeout(const Duration(seconds: 15), onTimeout: () => null);
        // Without a GPU (a CI machine) there is no ring to fill.
        if (first == null) return;
        final set = await client.gpuBufferSets.first;
        var releasing = true;
        var gpuFrames = 0;
        var pixelFrames = 0;
        Frame? previous;
        final frames = client.frames.listen((frame) {
          if (!frame.inGpuBuffer) {
            pixelFrames++;
            return;
          }
          gpuFrames++;
          final last = previous;
          if (releasing && last != null) {
            client.releaseGpuBuffer(last.gpuGeneration, last.bufferIndex);
          }
          previous = frame;
        });
        Future<Socket> view() => Socket.connect(
          InternetAddress(set.socket, type: InternetAddressType.unix),
          0,
        );
        var socket = await view();
        await Future<void>.delayed(const Duration(seconds: 1));
        // The rate before the tab hid: a slow machine (CI's x64 Mac) draws
        // well under 60 a second.
        final before = gpuFrames;
        releasing = false;
        previous = null;
        socket.destroy();
        await Future<void>.delayed(const Duration(seconds: 1));
        releasing = true;
        gpuFrames = 0;
        pixelFrames = 0;
        socket = await view();
        await Future<void>.delayed(const Duration(seconds: 1));
        socket.destroy();
        await frames.cancel();
        // Read back instead (#171's ring left full) or none at all (#319)?
        printOnFailure(
          'GPU frames a second: $before before, $gpuFrames after, with '
          '$pixelFrames read back; the runner last said:\n'
          '${runner.lastLines.join('\n')}',
        );
        // With the ring left full, none came at all. A slow machine (CI's
        // x64 Mac: 57 a second before, 23 in the first second back) takes
        // part of that second to come back up to speed.
        expect(gpuFrames, greaterThan(0));
        expect(gpuFrames, greaterThanOrEqualTo(before ~/ 4));
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'a view whose client holds its GPU ring leaves the other views their pace',
    () async {
      // raccoon#229: one vsync serves every view, and it waited for every
      // view's ring. A client that stops giving buffers back (a board frame
      // off screen, a tab hidden) held every view to the ring hold's ten
      // frames a second.
      final temp = Directory.systemTemp.createTempSync('raccoon_views');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final spinAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'spin',
        'build',
        'flutter_assets',
      );
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: spinAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          width: 320,
          height: 240,
          views: true,
        ),
      );
      final clients = [await RunnerClient.connect(endpoint, gpuBuffers: true)];
      final users = <_RingUser>[];
      final gpuSockets = <Socket>[];
      _HeldWatch? watch;
      try {
        final first = clients.first;
        final firstGpu = await first.frames
            .firstWhere((frame) => frame.inGpuBuffer)
            .then<Frame?>((frame) => frame)
            .timeout(const Duration(seconds: 15), onTimeout: () => null);
        // Without a GPU (a CI machine) there is no ring to hold.
        if (firstGpu == null) return;
        first.releaseGpuBuffer(firstGpu.gpuGeneration, firstGpu.bufferIndex);
        for (var i = 0; i < 2; i++) {
          final view = await RunnerClient.connect(
            endpoint.views,
            gpuBuffers: true,
          );
          clients.add(view);
          await view.hello.timeout(const Duration(seconds: 10));
          view.resize(320, 240, 1);
        }
        // One clock for the frames' arrivals, the hold and the counts.
        final clock = Stopwatch()..start();
        final epoch = DateTime.now().millisecondsSinceEpoch;
        for (final client in clients) {
          users.add(_RingUser(client, clock: clock));
          final set = await client.gpuBufferSets.first.timeout(
            const Duration(seconds: 10),
          );
          gpuSockets.add(
            await Socket.connect(
              InternetAddress(set.socket, type: InternetAddressType.unix),
              0,
            ),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
        watch = await _HeldWatch.start();
        final from = clock.elapsedMilliseconds;
        final before = await _framesOver(users, const Duration(seconds: 1));

        // The last view stops giving its buffers back.
        final holder = users.last;
        final holdFrom = clock.elapsedMilliseconds;
        holder.releasing = false;
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final heldFrom = clock.elapsedMilliseconds;
        final held = await _framesOver(users, const Duration(seconds: 1));
        final heldTo = clock.elapsedMilliseconds;

        holder.resume();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final after = await _framesOver(users, const Duration(seconds: 1));
        final to = clock.elapsedMilliseconds;
        final longest = await watch.stop();

        // How long this process was held up within the second counted with
        // the ring held.
        var heldUp = 0;
        for (final (at, millis) in watch.holds) {
          final start = at - epoch;
          heldUp += max(0, min(start + millis, heldTo) - max(start, heldFrom));
        }
        const bin = 250;
        String binned(_RingUser user, int at) {
          final inBin = user.arrivals.where(
            (arrival) => arrival.$1 >= at && arrival.$1 < at + bin,
          );
          final gpu = inBin.where((arrival) => arrival.$2).length;
          return '$gpu+${inBin.length - gpu}'.padLeft(7);
        }

        final timeline = [
          for (var at = from; at < to; at += bin)
            '${'${at - from}'.padLeft(6)} ms'
                '${users.map((user) => binned(user, at)).join()}',
        ];
        printOnFailure(
          '(GPU, read back) frames a second for views 0, 1, 2: $before '
          'before, $held with view 2 holding its ring, $after once it gave '
          'it back.\n'
          'View 2 held its ring from ${holdFrom - from} ms to '
          '${heldTo - from} ms; the second counted with it held began at '
          '${heldFrom - from} ms, and this process was held up for '
          '$heldUp ms of it. Held up at all (ms at): '
          '${watch.describe(epoch + from)}; the longest $longest ms.\n'
          'GPU+read back frames per $bin ms, views 0, 1, 2:\n'
          '${timeline.join('\n')}\n'
          'The runner last said:\n${runner.lastLines.join('\n')}',
        );
        // While this process is held up the client gives nothing back: two
        // frames fill each view's ring and the rest are dropped. So the
        // pace is kept over the time this process ran (#383).
        for (final view in [0, 1]) {
          expect(
            held[view].$1,
            greaterThanOrEqualTo(before[view].$1 * 3 * (1000 - heldUp) ~/ 4000),
            reason: 'view $view kept its pace',
          );
        }
        // The one holding its ring has nothing to draw into; what it gets is
        // read back, no faster than the hold's ten a second, as a client
        // alone gets it.
        expect(held[2].$2, lessThanOrEqualTo(12));
        // Given back, it is drawn into again.
        expect(after[2].$1, greaterThanOrEqualTo(before[2].$1 ~/ 2));
      } finally {
        await watch?.stop();
        for (final user in users) {
          await user.cancel();
        }
        for (final socket in gpuSockets) {
          socket.destroy();
        }
        for (final view in clients.skip(1)) {
          await view.close();
        }
        clients.first.shutdown();
        await clients.first.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'a view that comes back to a views run gets GPU frames again',
    () async {
      // #319 in a views run. A tab hidden: the view's GPU socket goes while
      // its client stays, and the frames drawn meanwhile fill its ring with
      // no one to give them back. Then the view's client goes altogether,
      // and a new one takes a view of its own.
      final temp = Directory.systemTemp.createTempSync('raccoon_views');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final spinAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'spin',
        'build',
        'flutter_assets',
      );
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: spinAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          width: 320,
          height: 240,
          views: true,
        ),
      );
      final first = await RunnerClient.connect(endpoint, gpuBuffers: true);
      final users = <_RingUser>[];
      final closing = <RunnerClient>[];
      final sockets = <Socket>[];
      Future<Socket> gpuSocket(RunnerClient client) async {
        final set = await client.gpuBufferSets.first.timeout(
          const Duration(seconds: 10),
        );
        final socket = await Socket.connect(
          InternetAddress(set.socket, type: InternetAddressType.unix),
          0,
        );
        sockets.add(socket);
        return socket;
      }

      Future<_RingUser> addView() async {
        final view = await RunnerClient.connect(
          endpoint.views,
          gpuBuffers: true,
        );
        closing.add(view);
        await view.hello.timeout(const Duration(seconds: 10));
        view.resize(320, 240, 1);
        final user = _RingUser(view);
        users.add(user);
        await gpuSocket(view);
        return user;
      }

      try {
        final firstGpu = await first.frames
            .firstWhere((frame) => frame.inGpuBuffer)
            .then<Frame?>((frame) => frame)
            .timeout(const Duration(seconds: 15), onTimeout: () => null);
        // Without a GPU (a CI machine) there is no ring to fill.
        if (firstGpu == null) return;
        first.releaseGpuBuffer(firstGpu.gpuGeneration, firstGpu.bufferIndex);
        final own = _RingUser(first);
        users.add(own);
        await gpuSocket(first);
        final view = await addView();
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final before = await _framesOver([
          own,
          view,
        ], const Duration(seconds: 1));

        // Hidden: its GPU socket goes, and nothing gives its frames back.
        view.releasing = false;
        sockets.last.destroy();
        await Future<void>.delayed(const Duration(seconds: 1));
        view.forget();
        await gpuSocket(view.client);
        view.resume();
        final shown = await _framesOver([
          own,
          view,
        ], const Duration(seconds: 1));

        // Gone, and a new view in its place.
        await view.cancel();
        sockets.last.destroy();
        await view.client.close();
        final next = await addView();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final replaced = await _framesOver([
          own,
          next,
        ], const Duration(seconds: 1));

        printOnFailure(
          '(GPU, read back) frames a second for view 0 and the other: '
          '$before before, $shown back from hidden, $replaced with a new '
          'view; the runner last said:\n${runner.lastLines.join('\n')}',
        );
        expect(shown[1].$1, greaterThanOrEqualTo(before[1].$1 ~/ 4));
        expect(replaced[1].$1, greaterThanOrEqualTo(before[1].$1 ~/ 4));
        expect(replaced[0].$1, greaterThanOrEqualTo(before[0].$1 * 3 ~/ 4));
      } finally {
        for (final user in users) {
          await user.cancel();
        }
        for (final socket in sockets) {
          socket.destroy();
        }
        for (final view in closing) {
          await view.close();
        }
        first.shutdown();
        await first.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );
  // #144: a client let go kept its GPU socket, which refused the next
  // client's and took its buffers.
  test(
    'a client that goes takes its GPU socket with it',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      try {
        final first = await RunnerClient.connect(endpoint, gpuBuffers: true);
        final GpuBuffers set;
        try {
          set = await first.gpuBufferSets.first.timeout(
            const Duration(seconds: 5),
          );
        } on TimeoutException {
          // No exporting renderer here: nothing to check.
          first.shutdown();
          await first.close();
          return;
        }
        // Stands in for the host's side of the GPU socket.
        final gpu = await Socket.connect(
          InternetAddress(set.socket, type: InternetAddressType.unix),
          0,
        );
        final gpuClosed = gpu.drain<void>().then((_) => true);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await first.close();
        expect(
          await gpuClosed.timeout(
            const Duration(seconds: 5),
            onTimeout: () => false,
          ),
          isTrue,
        );
        gpu.destroy();
        final last = await RunnerClient.connect(endpoint);
        await last.hello.timeout(const Duration(seconds: 5));
        last.shutdown();
        await last.close();
        expect(await _exitCode(runner), 0);
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'GPU sockets are Unix sockets',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
  // Built beside the runner on macOS: a GPU socket client that takes the
  // ring's surfaces by Mach port and checks them.
  final portCheck =
      binary == null ? '' : p.join(p.dirname(binary), 'raccoon_gpu_port_check');
  test(
    'on macOS the GPU socket hands out surfaces by Mach port, not global IDs',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final spinAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'spin',
        'build',
        'flutter_assets',
      );
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: spinAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint, gpuBuffers: true);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        final set = await client.gpuBufferSets.first.timeout(
          const Duration(seconds: 10),
        );
        // Buffers go back as frames come, so the ring keeps turning.
        Frame? previous;
        final frames = client.frames.listen((frame) {
          final last = previous;
          if (last != null && last.inGpuBuffer) {
            client.releaseGpuBuffer(last.gpuGeneration, last.bufferIndex);
          }
          previous = frame;
        });
        final check = await Process.run(portCheck, [set.socket]);
        await frames.cancel();
        printOnFailure('${check.stdout}${check.stderr}');
        expect(check.exitCode, 0);
        expect('${check.stdout}', contains('PORTS ok'));
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isMacOS
            ? 'Mach ports are macOS'
            : ready && File(portCheck).existsSync()
            ? false
            : 'build the runner and its port check first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'on macOS a client that never reaches the port service keeps global surfaces',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final spinAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'spin',
        'build',
        'flutter_assets',
      );
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: spinAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint, gpuBuffers: true);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        final set = await client.gpuBufferSets.first.timeout(
          const Duration(seconds: 10),
        );
        // Buffers go back as frames come, so the ring keeps turning.
        Frame? previous;
        final frames = client.frames.listen((frame) {
          final last = previous;
          if (last != null && last.inGpuBuffer) {
            client.releaseGpuBuffer(last.gpuGeneration, last.bufferIndex);
          }
          previous = frame;
        });
        // A sandboxed host's lookup fails: it takes the answer, asks
        // nothing, and must still find the surfaces by ID.
        final check = await Process.run(portCheck, [set.socket, '--never-ask']);
        await frames.cancel();
        printOnFailure('${check.stdout}${check.stderr}');
        expect(check.exitCode, 0);
        expect('${check.stdout}', contains('GLOBAL ok'));
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isMacOS
            ? 'Mach ports are macOS'
            : ready && File(portCheck).existsSync()
            ? false
            : 'build the runner and its port check first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'on macOS a token given to one client is not good after the next answer',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final spinAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'spin',
        'build',
        'flutter_assets',
      );
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: spinAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint, gpuBuffers: true);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        final set = await client.gpuBufferSets.first.timeout(
          const Duration(seconds: 10),
        );
        // Buffers go back as frames come, so the ring keeps turning.
        Frame? previous;
        final frames = client.frames.listen((frame) {
          final last = previous;
          if (last != null && last.inGpuBuffer) {
            client.releaseGpuBuffer(last.gpuGeneration, last.bufferIndex);
          }
          previous = frame;
        });
        // #161: a request from a client that has gone, still queued, must
        // not count as the next client's ask.
        final check = await Process.run(portCheck, [set.socket, '--renew']);
        await frames.cancel();
        printOnFailure('${check.stdout}${check.stderr}');
        expect(check.exitCode, 0);
        expect('${check.stdout}', contains('RENEW ok'));
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isMacOS
            ? 'Mach ports are macOS'
            : ready && File(portCheck).existsSync()
            ? false
            : 'build the runner and its port check first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'on macOS the rings go global again for the client after one that took ports',
    () async {
      // #153: a client that cannot reach the service, after one that made
      // the rings private, must find its surfaces by ID again.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final spinAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'spin',
        'build',
        'flutter_assets',
      );
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: spinAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      try {
        for (final mode in ['', '--never-ask']) {
          // The runner may not have seen the last client go yet, and
          // answers Busy until it has.
          late RunnerClient client;
          for (var attempt = 0; ; attempt++) {
            client = await RunnerClient.connect(endpoint, gpuBuffers: true);
            try {
              await client.hello;
              break;
            } on RunnerBusy {
              await client.close();
              if (attempt == 20) rethrow;
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          }
          final set = await client.gpuBufferSets.first.timeout(
            const Duration(seconds: 10),
          );
          Frame? previous;
          final frames = client.frames.listen((frame) {
            final last = previous;
            if (last != null && last.inGpuBuffer) {
              client.releaseGpuBuffer(last.gpuGeneration, last.bufferIndex);
            }
            previous = frame;
          });
          final check = await Process.run(portCheck, [
            set.socket,
            if (mode.isNotEmpty) mode,
          ]);
          await frames.cancel();
          printOnFailure('$mode: ${check.stdout}${check.stderr}');
          expect(check.exitCode, 0, reason: mode);
          await client.close();
        }
      } finally {
        final client = await RunnerClient.connect(endpoint);
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isMacOS
            ? 'Mach ports are macOS'
            : ready && File(portCheck).existsSync()
            ? false
            : 'build the runner and its port check first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  // Built beside the runner on Windows: a GPU socket client that opens the
  // ring's textures by their shared handles and checks the frame in them.
  final handleCheck =
      binary == null
          ? ''
          : p.join(p.dirname(binary), 'raccoon_gpu_handle_check.exe');
  test(
    'on Windows a client opens the ring by its shared handles and finds the frame',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint, gpuBuffers: true);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        // Without a Vulkan device (a CI machine) the runner rasterizes in
        // software and offers no textures: nothing to open.
        if (runner.renderer != 'vulkan') {
          printOnFailure('renderer ${runner.renderer}, no shared textures');
          return;
        }
        final set = await client.gpuBufferSets.first.timeout(
          const Duration(seconds: 10),
        );
        await client.frames
            .firstWhere((frame) => frame.inGpuBuffer)
            .timeout(const Duration(seconds: 10));
        final check = await Process.run(handleCheck, [set.socket]);
        printOnFailure('${check.stdout}${check.stderr}');
        expect(check.exitCode, 0);
        expect('${check.stdout}', contains('HANDLES ok'));
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isWindows
            ? 'shared D3D11 textures are Windows'
            : ready && File(handleCheck).existsSync()
            ? false
            : 'build the runner and its handle check first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'on Windows clients that take the ring and hang up mid-frame leave the runner drawing',
    () async {
      // The spin example animates, so the raster thread is mostly between
      // taking a buffer and presenting it when a client leaves (#126).
      final spinAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'spin',
        'build',
        'flutter_assets',
      );
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: spinAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      int? exited;
      unawaited(runner.exitCode.then((code) => exited = code));
      try {
        for (var i = 0; i < 100; i++) {
          final client = await RunnerClient.connect(endpoint, gpuBuffers: true);
          await client.hello.timeout(const Duration(seconds: 10));
          if (runner.renderer != 'vulkan') {
            printOnFailure('renderer ${runner.renderer}, no ring');
            client.shutdown();
            await client.close();
            return;
          }
          final first = Completer<void>();
          final frames = client.frames.listen((_) {
            if (!first.isCompleted) first.complete();
          });
          await first.future.timeout(
            const Duration(seconds: 10),
            onTimeout: () => fail('client $i got no frame; exited $exited'),
          );
          await Future<void>.delayed(Duration(milliseconds: i % 7));
          await frames.cancel();
          await client.close();
        }
        // Freed under the engine, the ring crashed the runner within 40
        // clients in four runs of five, or the engine stopped drawing.
        final client = await RunnerClient.connect(endpoint);
        await client.hello.timeout(const Duration(seconds: 10));
        var count = 0;
        final frames = client.frames.listen((_) => count++);
        await Future<void>.delayed(const Duration(seconds: 1));
        await frames.cancel();
        expect(count, greaterThan(20));
        client.shutdown();
        await client.close();
        await _expectExit(runner);
      } finally {
        if (exited == null) runner.kill();
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isWindows
            ? 'the Vulkan ring is Windows'
            : ready
            ? false
            : 'build the runner first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'a client that imports GPU buffers gets frames as buffer indices and their descriptors on the GPU socket',
    () async {
      // The spin example animates, so frames keep coming.
      final spinAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'spin',
        'build',
        'flutter_assets',
      );
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: spinAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint, gpuBuffers: true);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        // Only a renderer that exports offers them; otherwise frames come by
        // readback and the test has nothing to check.
        final GpuBuffers set;
        try {
          set = await client.gpuBufferSets.first.timeout(
            const Duration(seconds: 5),
          );
        } on TimeoutException {
          final frame = await client.frames.first.timeout(
            const Duration(seconds: 10),
          );
          expect(frame.inGpuBuffer, isFalse);
          printOnFailure('no GPU buffers offered: ${client.latestGpuBuffers}');
          return;
        }
        expect(set.count, 4);
        expect(set.generation, greaterThan(0));
        expect(set.width, 800);
        expect(set.height, 600);
        expect(set.strides, hasLength(4));
        expect(set.socket, p.join(temp.path, 'runner.gpu'));

        // Frames are indices now, no pixels; giving them back keeps them
        // coming past the ring's size.
        final frames = <Frame>[];
        final done = Completer<void>();
        // Later, buffers go back over the GPU socket instead.
        late RawSocket gpuSocket;
        var releaseOnSocket = false;
        final socketFrames = <Frame>[];
        final doneOnSocket = Completer<void>();
        // Last, buffers are held: the ring starves, then the GPU socket's
        // client goes away and they are the runner's again.
        var hold = false;
        final starved = Completer<void>();
        final freed = Completer<void>();
        var afterStarving = 0;
        final subscription = client.frames.listen((frame) {
          frames.add(frame);
          if (hold) {
            if (!frame.inGpuBuffer && !starved.isCompleted) starved.complete();
            if (frame.inGpuBuffer && starved.isCompleted) afterStarving++;
            if (afterStarving >= 2 && !freed.isCompleted) freed.complete();
            return;
          }
          if (frame.inGpuBuffer) {
            if (releaseOnSocket) {
              socketFrames.add(frame);
              gpuSocket.write(_release(frame.gpuGeneration, frame.bufferIndex));
              if (socketFrames.length >= 8 && !doneOnSocket.isCompleted) {
                doneOnSocket.complete();
              }
            } else {
              client.releaseGpuBuffer(frame.gpuGeneration, frame.bufferIndex);
            }
          }
          if (frames.length >= 8 && !done.isCompleted) done.complete();
        });
        await done.future.timeout(const Duration(seconds: 15));
        expect(frames.where((f) => f.inGpuBuffer), isNotEmpty);
        expect(
          frames.where((f) => f.inGpuBuffer).every((f) => f.pixels.isEmpty),
          isTrue,
        );
        expect(
          frames
              .where((f) => f.inGpuBuffer)
              .map((f) => f.bufferIndex)
              .toSet()
              .length,
          greaterThan(1),
        );

        // The GPU socket serves the same description: on Linux with one
        // descriptor per buffer riding along, on macOS with the surfaces'
        // IDs after the pairs and nothing riding along, on Windows with the
        // textures' shared handles there instead.
        gpuSocket = await RawSocket.connect(
          InternetAddress(set.socket, type: InternetAddressType.unix),
          0,
        );
        final handles = <ResourceHandle>[];
        final bytes = <int>[];
        final described = Completer<void>();
        gpuSocket.listen((event) {
          if (event != RawSocketEvent.read) return;
          if (Platform.isWindows) {
            bytes.addAll(gpuSocket.read() ?? const []);
          } else {
            final message = gpuSocket.readMessage();
            if (message == null) return;
            bytes.addAll(message.data);
            for (final control in message.controlMessages) {
              handles.addAll(control.extractHandles());
            }
          }
          final whole = MessageUnframer()
              .add(Uint8List.fromList(bytes))
              .any((m) => String.fromCharCodes(m.sublist(0, 4)) == 'RGPU');
          if (whole &&
              (!Platform.isLinux || handles.length >= 4) &&
              !described.isCompleted) {
            described.complete();
          }
        });
        await described.future.timeout(const Duration(seconds: 10));
        final messages =
            MessageUnframer().add(Uint8List.fromList(bytes)).toList();
        expect(messages, isNotEmpty);
        // A fixed layout, so a native client needs no protobuf.
        final data = ByteData.sublistView(messages.first);
        expect(String.fromCharCodes(messages.first.sublist(0, 4)), 'RGPU');
        expect(data.getUint32(4, Endian.little), set.generation);
        expect(data.getUint32(8, Endian.little), 4);
        expect(data.getUint32(12, Endian.little), set.width);
        expect(data.getUint32(16, Endian.little), set.height);
        expect(data.getUint32(20, Endian.little), set.fourcc);
        if (!Platform.isLinux) {
          expect(messages.first.length, 32 + 4 * 8 + 4 * 4);
          final ids = [
            for (var i = 0; i < 4; i++)
              data.getUint32(32 + 4 * 8 + i * 4, Endian.little),
          ];
          expect(ids.toSet(), hasLength(4));
          expect(ids, everyElement(isNot(0)));
          expect(handles, isEmpty);
        } else {
          expect(messages.first.length, 32 + 4 * 8);
          expect(handles.length, greaterThanOrEqualTo(4));
        }

        // Where EGL has native fences, each frame's fence comes ahead of it:
        // 'RFEN', generation, index, one descriptor riding along. Metal
        // names a frame once it is drawn instead, so there are none.
        List<Uint8List> fences() =>
            MessageUnframer()
                .add(Uint8List.fromList(bytes))
                .where((m) => String.fromCharCodes(m.sublist(0, 4)) == 'RFEN')
                .toList();
        final deadline = DateTime.now().add(
          Platform.isMacOS ? Duration.zero : const Duration(seconds: 3),
        );
        while (fences().isEmpty && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        final fenced = fences();
        final handleCount = handles.length;
        if (fenced.isEmpty) {
          printOnFailure('no fences from this renderer');
        } else {
          expect(fenced.every((m) => m.length == 12), isTrue);
          expect(
            fenced
                .map((m) => ByteData.sublistView(m).getUint32(4, Endian.little))
                .toSet(),
            {set.generation},
          );
          expect(handleCount, 4 + fenced.length);
        }

        // Buffers can be given back on this socket too: 'RREL', generation,
        // index, fenced; frames keep coming past the ring's size.
        releaseOnSocket = true;
        await doneOnSocket.future.timeout(const Duration(seconds: 15));
        expect(
          socketFrames.map((f) => f.bufferIndex).toSet().length,
          greaterThan(1),
        );

        // Held buffers starve the ring into readback; once the client on
        // the GPU socket is gone, the runner takes them all back.
        hold = true;
        await starved.future.timeout(const Duration(seconds: 15));
        await gpuSocket.close();
        await freed.future.timeout(const Duration(seconds: 15));
        await subscription.cancel();
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  // #123: a ring's descriptors were copied as numbers and sent after the
  // renderer's lock, and a pool rebuilt meanwhile closed them, its own
  // taking the same numbers: a client could get the next ring's dmabufs
  // under the generation before.
  test(
    'on Linux each ring on the GPU socket comes with its own dmabufs while the view resizes',
    () async {
      final spinAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'spin',
        'build',
        'flutter_assets',
      );
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: spinAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint, gpuBuffers: true);
      RawSocket? gpuSocket;
      try {
        final frames = client.frames.listen((frame) {
          if (frame.inGpuBuffer) {
            client.releaseGpuBuffer(frame.gpuGeneration, frame.bufferIndex);
          }
        });
        await client.hello.timeout(const Duration(seconds: 10));
        final GpuBuffers set;
        try {
          set = await client.gpuBufferSets.first.timeout(
            const Duration(seconds: 5),
          );
        } on TimeoutException {
          await frames.cancel();
          printOnFailure('no GPU buffers offered');
          return;
        }

        // Each ring as described, with the size of each dmabuf that came
        // with it.
        final rings =
            <
              ({int generation, int height, List<int> strides, List<int> sizes})
            >[];
        final handles = <ResourceHandle>[];
        final bytes = <int>[];
        final socket =
            gpuSocket = await RawSocket.connect(
              InternetAddress(set.socket, type: InternetAddressType.unix),
              0,
            );
        socket.listen((event) {
          if (event != RawSocketEvent.read) return;
          final message = socket.readMessage();
          if (message == null) return;
          bytes.addAll(message.data);
          for (final control in message.controlMessages) {
            handles.addAll(control.extractHandles());
          }
          while (bytes.length >= 4) {
            final length = ByteData.sublistView(
              Uint8List.fromList(bytes.sublist(0, 4)),
            ).getUint32(0, Endian.little);
            if (bytes.length < 4 + length) break;
            final body = Uint8List.fromList(bytes.sublist(4, 4 + length));
            bytes.removeRange(0, 4 + length);
            final data = ByteData.sublistView(body);
            switch (String.fromCharCodes(body.sublist(0, 4))) {
              case 'RGPU':
                final count = data.getUint32(8, Endian.little);
                final taken = handles.take(count).toList();
                handles.removeRange(0, taken.length);
                final sizes = <int>[];
                for (final handle in taken) {
                  final file = handle.toFile();
                  sizes.add(file.lengthSync());
                  file.closeSync();
                }
                rings.add((
                  generation: data.getUint32(4, Endian.little),
                  height: data.getUint32(16, Endian.little),
                  strides: [
                    for (var i = 0; i < count; i++)
                      data.getUint32(32 + i * 8, Endian.little),
                  ],
                  sizes: sizes,
                ));
              case 'RFEN':
                if (handles.isNotEmpty) {
                  handles.removeAt(0).toFile().closeSync();
                }
            }
          }
        });
        // Two sizes in turn: each resize builds a ring anew.
        for (var i = 0; i < 40; i++) {
          client.resize(i.isEven ? 1200 : 800, i.isEven ? 900 : 600, 1);
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await frames.cancel();
        printOnFailure('${rings.length} rings: $rings');
        expect(rings.length, greaterThan(2));
        for (final ring in rings) {
          expect(ring.sizes, hasLength(ring.strides.length));
          for (var i = 0; i < ring.sizes.length; i++) {
            expect(
              ring.sizes[i],
              greaterThanOrEqualTo(ring.strides[i] * ring.height),
              reason: 'buffer $i of generation ${ring.generation}',
            );
          }
        }
      } finally {
        await gpuSocket?.close();
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isLinux
            ? 'dmabufs are Linux'
            : ready
            ? false
            : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );
}

/// A release of buffer [index] of [generation] as the GPU socket takes it,
/// framed, without a fence.
Uint8List _release(int generation, int index) {
  final payload =
      ByteData(16)
        ..setUint32(4, generation, Endian.little)
        ..setUint32(8, index, Endian.little)
        ..setUint32(12, 0, Endian.little);
  payload.buffer.asUint8List().setAll(0, 'RREL'.codeUnits);
  return MessageFraming.frame(payload.buffer.asUint8List());
}

/// How long this process went without running, at the longest, while a
/// test waits: an isolate of its own ticks every few milliseconds, so the
/// test's own work doesn't count, only a machine that held the whole
/// process up.
class _HeldWatch {
  _HeldWatch._(this._isolate, this._replies, this._stop);

  static const _tick = Duration(milliseconds: 2);

  /// A hold this long or longer, past the tick, is kept in [holds].
  static const _noted = 20;

  final Isolate _isolate;
  final StreamIterator<Object?> _replies;
  final SendPort _stop;
  Future<int>? _stopped;

  /// The holds of [_noted] ms or more, once stopped: when each started, in
  /// milliseconds since the epoch, and how long it was.
  var holds = const <(int, int)>[];

  static Future<_HeldWatch> start() async {
    final port = ReceivePort();
    final replies = StreamIterator<Object?>(port);
    final isolate = await Isolate.spawn(_watch, port.sendPort);
    await replies.moveNext();
    return _HeldWatch._(isolate, replies, replies.current! as SendPort);
  }

  /// The longest time the watch went without a tick, past its own tick.
  /// Again, the same answer.
  Future<int> stop() => _stopped ??= _stopOnce();

  Future<int> _stopOnce() async {
    _stop.send(null);
    await _replies.moveNext();
    final [longest as int, ...noted] = _replies.current! as List<Object?>;
    await _replies.cancel();
    _isolate.kill();
    holds = [
      for (var i = 0; i < noted.length; i += 2)
        (noted[i]! as int, noted[i + 1]! as int),
    ];
    return max(0, longest - _tick.inMilliseconds);
  }

  /// [holds] for a failure's message, from [since] (since the epoch).
  String describe(int since) =>
      holds.isEmpty
          ? 'none of $_noted ms or more'
          : holds
              .map((hold) => '${hold.$2} ms at ${hold.$1 - since}')
              .join(', ');

  static void _watch(SendPort out) {
    final control = ReceivePort();
    out.send(control.sendPort);
    final clock = Stopwatch()..start();
    final epoch = DateTime.now().millisecondsSinceEpoch;
    var last = 0;
    var longest = 0;
    final noted = <int>[];
    void tick() {
      final now = clock.elapsedMilliseconds;
      final gap = now - last;
      longest = max(longest, gap);
      final held = gap - _tick.inMilliseconds;
      if (held >= _noted) noted.addAll([epoch + last, held]);
      last = now;
    }

    final ticks = Timer.periodic(_tick, (_) => tick());
    control.first.then((_) {
      ticks.cancel();
      tick();
      out.send([longest, ...noted]);
      control.close();
    });
  }
}

/// A host's use of a client's GPU ring, as a board frame's texture uses it:
/// each frame shown gives the one before back, unless [releasing] is off
/// (a frame off screen, a tab hidden), when it keeps every one it gets.
class _RingUser {
  _RingUser(this.client, {this.clock}) {
    _frames = client.frames.listen(_onFrame);
  }

  final RunnerClient client;
  late final StreamSubscription<Frame> _frames;
  final _held = <Frame>[];
  var releasing = true;
  var gpuFrames = 0;
  var pixelFrames = 0;

  /// With a [clock], when each frame came on it, and whether in a GPU
  /// buffer.
  final Stopwatch? clock;
  final arrivals = <(int, bool)>[];

  void _onFrame(Frame frame) {
    if (clock case final clock?) {
      arrivals.add((clock.elapsedMilliseconds, frame.inGpuBuffer));
    }
    if (!frame.inGpuBuffer) {
      pixelFrames++;
      return;
    }
    gpuFrames++;
    _held.add(frame);
    if (releasing) _releaseAllBut(1);
  }

  void _releaseAllBut(int kept) {
    while (_held.length > kept) {
      final frame = _held.removeAt(0);
      client.releaseGpuBuffer(frame.gpuGeneration, frame.bufferIndex);
    }
  }

  /// Gives back what it held, and every frame before the newest from now.
  void resume() {
    releasing = true;
    _releaseAllBut(1);
  }

  /// Forgets what it held without giving it back: its view went.
  void forget() => _held.clear();

  void reset() {
    gpuFrames = 0;
    pixelFrames = 0;
  }

  Future<void> cancel() => _frames.cancel();
}

/// GPU and read-back frames each of [users] gets over [span], counted from
/// zero.
Future<List<(int, int)>> _framesOver(
  List<_RingUser> users,
  Duration span,
) async {
  for (final user in users) {
    user.reset();
  }
  await Future<void>.delayed(span);
  return [for (final user in users) (user.gpuFrames, user.pixelFrames)];
}

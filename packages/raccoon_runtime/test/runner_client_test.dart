import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:path/path.dart' as p;
import 'package:raccoon/raccoon.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

/// A runner stand-in on a Unix socket: one client, messages framed both
/// ways, and what the client sent kept.
final class _Runner {
  _Runner._(this._server) {
    _server.listen((socket) {
      _client = socket;
      socket.listen((bytes) {
        for (final payload in _unframer.add(bytes)) {
          _received.add(ClientMessage.fromBuffer(payload));
        }
      });
      send(RunnerMessage(hello: RunnerHello(protocolVersion: 1, pid: 7)));
      _connected.complete();
    });
  }

  static Future<_Runner> start(String path) async => _Runner._(
    await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    ),
  );

  final ServerSocket _server;
  final _unframer = MessageUnframer();
  final _received = StreamController<ClientMessage>.broadcast();
  final _connected = Completer<void>();
  Socket? _client;

  Stream<ClientMessage> get received => _received.stream;

  Future<void> get connected => _connected.future;

  void send(RunnerMessage message) =>
      _client?.add(MessageFraming.frame(message.writeToBuffer()));

  /// [messages] framed and written at once, so a test times the client
  /// rather than a socket write per message, which Windows makes slow.
  void sendAll(Iterable<RunnerMessage> messages) {
    final out = BytesBuilder(copy: false);
    for (final message in messages) {
      out.add(MessageFraming.frame(message.writeToBuffer()));
    }
    _client?.add(out.takeBytes());
  }

  /// [payload] framed as a message, whatever it is.
  void raw(List<int> payload) => _client?.add(MessageFraming.frame(payload));

  void log(String line) =>
      send(RunnerMessage(log: LogLine(tag: 'stderr', message: line)));

  void frame() => send(
    RunnerMessage(
      frame: Frame(
        sequence: Int64(1),
        width: 1,
        height: 1,
        rowBytes: 4,
        pixels: [0, 0, 0, 255],
      ),
    ),
  );

  Future<void> stop() async {
    await _client?.close();
    await _server.close();
  }
}

const _exception =
    '[ERROR:flutter/runtime/dart_vm_initializer.cc(40)] Unhandled Exception: '
    'PlatformException(channel-error, Unable to establish connection on '
    'channel: "dev.flutter.pigeon.absent_plugin.AbsentHostApi.initialize"., '
    'null, null)';
const _unanswered =
    'raccoon_runner: nothing answered '
    'dev.flutter.pigeon.absent_plugin.AbsentHostApi.initialize (no client); '
    'the app sees no plugin';

void main() {
  late Directory temp;
  late _Runner runner;
  late RunnerClient client;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('raccoon_client');
    final path = p.join(temp.path, 'app.sock');
    runner = await _Runner.start(path);
    client = await RunnerClient.connect(
      UnixSocketEndpoint(path),
      startupGrace: const Duration(milliseconds: 100),
    );
    await runner.connected;
    await client.hello;
  });

  tearDown(() async {
    await client.close();
    await runner.stop();
    temp.deleteSync(recursive: true);
  });

  test(
    'a report takes the exception the Dart VM prints on the next line',
    () async {
      // A failure reported for a channel, then the VM's own form: the
      // marker alone, the text on the line after, no stack.
      runner.log(_unanswered);
      await client.startupFailures
          .firstWhere((failure) => failure != null)
          .timeout(const Duration(seconds: 5));
      runner
        ..log('Unhandled exception:')
        ..log('Bad state: boom');
      final failure = await client.startupFailures
          .firstWhere((failure) => failure?.exception == 'Bad state: boom')
          .timeout(const Duration(seconds: 5));
      expect(failure?.exception, 'Bad state: boom');
    },
  );

  test('an app that logs a lot before its first frame costs little to '
      'follow', () async {
    // #163: every line read the whole startup window again, two regexes
    // a line, so 150,000 lines took about 20 seconds.
    runner.sendAll([
      for (var i = 0; i < 150000; i++)
        RunnerMessage(
          log: LogLine(tag: 'stdout', message: 'flutter: step $i of a start'),
        ),
      RunnerMessage(log: LogLine(tag: 'stderr', message: _unanswered)),
    ]);
    final stopwatch = Stopwatch()..start();
    runner.frame();
    await client.frames.first.timeout(const Duration(seconds: 30));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 6)));
    expect(client.startupLog, isEmpty, reason: 'the first frame ends it');
  });

  test('a message that does not parse ends the client, with no uncaught '
      'error', () async {
    // A stream that stops being the protocol can't be trusted to be framed
    // right after it either.
    final errors = <Object>[];
    client.messages.listen((_) {}, onError: errors.add);
    runner.raw([0xff, 0xff, 0xff, 0xff]);
    await client.closed.timeout(const Duration(seconds: 5));
    expect(errors, hasLength(1));
  });

  test('a message that does not parse reaches frames and messages once; '
      'the other streams just end', () async {
    // #227: listeners on text fields, plugins and GPU buffers rarely say
    // what to do with an error, and the client's end is told on frames.
    final frameErrors = <Object>[];
    final uncaught = <Object>[];
    final ended = <Future<void>>[];
    runZonedGuarded(() {
      client.frames.listen((_) {}, onError: frameErrors.add);
      for (final stream in <Stream<Object>>[
        client.textFields,
        client.plugins,
        client.gpuBufferSets,
      ]) {
        final done = Completer<void>();
        stream.listen((_) {}, onDone: done.complete);
        ended.add(done.future);
      }
    }, (error, _) => uncaught.add(error));
    runner.raw([0xff, 0xff, 0xff, 0xff]);
    await client.closed.timeout(const Duration(seconds: 5));
    await Future.wait(ended).timeout(const Duration(seconds: 5));
    expect(frameErrors, hasLength(1));
    expect(uncaught, isEmpty);
  });

  test('what is sent while the runner reads slowly arrives whole and in '
      'order', () async {
    // #227: a backlog is written from its head, not joined again per write.
    const count = 3000;
    final ids = <int>[];
    final all = runner.received
        .where((m) => m.hasPlatformResponse())
        .take(count)
        .forEach((m) => ids.add(m.platformResponse.responseId.toInt()));
    for (var i = 0; i < count; i++) {
      client.send(
        ClientMessage(
          platformResponse: PlatformResponse(
            responseId: Int64(i),
            handled: true,
            data: Uint8List(i % 500 == 0 ? 1 << 18 : 16),
          ),
        ),
      );
    }
    await all.timeout(const Duration(seconds: 30));
    expect(ids, List.generate(count, (i) => i));
  });

  test('an app that died before its first frame is reported, with the '
      'plugin behind it', () async {
    final reports = <StartupFailure?>[];
    final subscription = client.startupFailures.listen(reports.add);
    runner
      ..log(_unanswered)
      ..log(_exception)
      ..log('#0      main (package:no_plugin/main.dart:24:5)');
    final failure = await client.startupFailures
        .firstWhere((failure) => failure != null)
        .timeout(const Duration(seconds: 5));
    expect(failure?.exception, startsWith('PlatformException(channel-error'));
    expect(failure?.hints, isEmpty);

    // The plugin report comes after the lines: the hint follows at once.
    runner.send(
      RunnerMessage(
        plugins: Plugins(
          plugins: [
            PluginReport(
              name: 'absent_plugin',
              state: PluginState.PLUGIN_STATE_NO_HOST,
              detail: 'no Linux implementation',
            ),
          ],
        ),
      ),
    );
    final hinted = await client.startupFailures
        .firstWhere((failure) => failure?.hints.isNotEmpty ?? false)
        .timeout(const Duration(seconds: 5));
    expect(hinted?.hints, ['absent_plugin has no Linux implementation']);
    await subscription.cancel();
    expect(reports.first, isNull);
  });

  test(
    'a frame within the grace means the app went on: nothing to say',
    () async {
      runner
        ..log(_unanswered)
        ..frame();
      await client.frames.first.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(client.startupFailure, isNull);
      expect(client.startupLog, isEmpty);
    },
  );

  test('a runner that hangs up before its hello fails hello', () async {
    final path = p.join(temp.path, 'silent.sock');
    final silent = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    silent.listen((socket) => socket.destroy());
    final other = await RunnerClient.connect(UnixSocketEndpoint(path));
    await expectLater(
      other.hello.timeout(const Duration(seconds: 5)),
      throwsA(isA<SocketException>()),
    );
    await other.close();
    await silent.close();
  });

  test('close sends what is still queued, a Shutdown above all', () async {
    // More than a Unix socket takes at once (about 200 KB on Linux, 8 KB on
    // macOS), so most of it is still queued when close comes; the Shutdown
    // behind it must reach the runner anyway. Not much more: the stand-in
    // runner reassembles it slowly, and close waits only so long.
    final shutdown = runner.received.firstWhere((m) => m.hasShutdown());
    client
      ..send(
        ClientMessage(
          platformResponse: PlatformResponse(
            responseId: Int64(1),
            handled: true,
            data: Uint8List(1 << 20),
          ),
        ),
      )
      ..shutdown();
    await client.close();
    await shutdown.timeout(const Duration(seconds: 10));
  });

  test('insets go with the next size, or wait for it', () async {
    final sent = <Resize>[];
    final subscription = runner.received
        .where((message) => message.hasResize())
        .listen((message) => sent.add(message.resize));
    client
      ..resize(1170, 2532, 3)
      ..setViewInsets(bottom: 1008)
      // A host about to resize the view: the insets wait for its size.
      ..setViewInsets(bottom: 796, resend: false)
      ..resize(1640, 2360, 2);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await subscription.cancel();
    expect(
      [for (final resize in sent) (resize.width, resize.viewInsetBottom)],
      [(1170, 0.0), (1170, 1008.0), (1640, 796.0)],
    );
  });

  test('once a frame arrived, the log no longer counts', () async {
    runner
      ..log(_exception)
      ..log('#0      main (package:no_plugin/main.dart:24:5)');
    await client.startupFailures
        .firstWhere((failure) => failure != null)
        .timeout(const Duration(seconds: 5));

    runner.frame();
    await client.startupFailures
        .firstWhere((failure) => failure == null)
        .timeout(const Duration(seconds: 5));
    runner.log(_exception);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(client.startupFailure, isNull);
  });

  test('a channel without a handler is answered "not handled"', () async {
    final reply = runner.received.firstWhere((m) => m.hasPlatformResponse());
    runner.send(
      RunnerMessage(
        platformMessage: PlatformMessage(
          responseId: Int64(3),
          channel: 'plugins.flutter.io/absent_plugin',
          data: utf8.encode('{}'),
        ),
      ),
    );
    final response =
        (await reply.timeout(const Duration(seconds: 5))).platformResponse;
    expect(response.responseId, Int64(3));
    expect(response.handled, isFalse);
  });

  // #134: the error went into messages, and a view took it for a lost
  // runner.
  test('a handler that throws still answers, "not handled", and the '
      'connection goes on', () async {
    final errors = <Object>[];
    final frameErrors = <Object>[];
    final subscription = client.channelErrors.listen(null, onError: errors.add);
    final frames = client.frames.listen(null, onError: frameErrors.add);
    client.registerChannel(
      'plugins.flutter.io/broken',
      (Uint8List data) async => throw StateError('broken'),
    );
    final reply = runner.received.firstWhere((m) => m.hasPlatformResponse());
    runner.send(
      RunnerMessage(
        platformMessage: PlatformMessage(
          responseId: Int64(4),
          channel: 'plugins.flutter.io/broken',
        ),
      ),
    );
    final response =
        (await reply.timeout(const Duration(seconds: 5))).platformResponse;
    expect(response.responseId, Int64(4));
    expect(response.handled, isFalse);
    expect(errors.single, isA<StateError>());
    runner.frame();
    await client.frames.first.timeout(const Duration(seconds: 5));
    expect(frameErrors, isEmpty);
    await subscription.cancel();
    await frames.cancel();
  });

  // #134: every line restarted the grace, so an app that kept logging after
  // it died was never reported.
  test('an app that goes on logging after it died is reported', () async {
    final reported = client.startupFailures
        .firstWhere((failure) => failure != null)
        .timeout(const Duration(seconds: 5));
    runner
      ..log(_exception)
      ..log('#0      main (package:no_plugin/main.dart:24:5)');
    final ticking = Timer.periodic(
      const Duration(milliseconds: 30),
      (_) => runner.log('still ticking'),
    );
    addTearDown(ticking.cancel);
    expect(await reported, isNotNull);
  });

  // #134: a frame in a buffer the client does not hold was dropped and
  // kept busy, so the runner sent every frame inline after it.
  test(
    'a frame in a buffer the client lacks is dropped and given back',
    () async {
      final release = runner.received.firstWhere((m) => m.hasReleaseBuffer());
      runner.send(
        RunnerMessage(
          frame: Frame(
            sequence: Int64(1),
            width: 1,
            height: 1,
            rowBytes: 4,
            inSharedBuffer: true,
            bufferIndex: 5,
          ),
        ),
      );
      final message = await release.timeout(const Duration(seconds: 5));
      expect(message.releaseBuffer.index, 5);
      expect(message.releaseBuffer.generation, 0);
      expect(client.latestFrame, isNull);
    },
  );

  // #145: a later listener was given the last GPU frame, whose buffer an
  // earlier one may have given back.
  test('a frame in a GPU buffer is not replayed to a later listener', () async {
    runner.send(
      RunnerMessage(
        frame: Frame(
          sequence: Int64(1),
          width: 1,
          height: 1,
          inGpuBuffer: true,
          bufferIndex: 0,
          gpuGeneration: 1,
        ),
      ),
    );
    await client.messages
        .firstWhere((m) => m.hasFrame())
        .timeout(const Duration(seconds: 5));
    expect(client.latestFrame?.inGpuBuffer, isTrue);
    final replayed = await client.frames.first
        .then<Frame?>((f) => f)
        .timeout(const Duration(milliseconds: 300), onTimeout: () => null);
    expect(replayed, isNull);

    // A frame with pixels still is.
    runner.frame();
    await client.messages
        .firstWhere((m) => m.hasFrame())
        .timeout(const Duration(seconds: 5));
    final again = await client.frames.first.timeout(const Duration(seconds: 1));
    expect(again.inGpuBuffer, isFalse);
  });
}

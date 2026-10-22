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

  test('a handler that throws still answers, "not handled"', () async {
    final errors = <Object>[];
    final subscription = client.messages.listen((_) {}, onError: errors.add);
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
    await subscription.cancel();
  });
}

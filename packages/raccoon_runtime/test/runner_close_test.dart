import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:path/path.dart' as p;
import 'package:raccoon/raccoon.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

/// A runner stand-in in an isolate of its own, so it keeps writing while
/// the test's isolate is blocked: it says hello, sends [_flood] bytes of
/// frames, and reads nothing until told the client is closing, as a runner
/// busy writing frames would. Then it reports whether a Shutdown came, and
/// hangs up.
Future<void> _busyRunner((String, SendPort) args) async {
  final (path, report) = args;
  final commands = ReceivePort();
  report.send(commands.sendPort);
  final server = await ServerSocket.bind(
    InternetAddress(path, type: InternetAddressType.unix),
    0,
  );
  final socket = await server.first;
  final unframer = MessageUnframer();
  var shutdown = false;
  // A reset fails the reads and the writes; what counts is the Shutdown.
  socket.done.ignore();
  final reading = socket.listen((bytes) {
    for (final payload in unframer.add(bytes)) {
      if (ClientMessage.fromBuffer(payload).hasShutdown()) shutdown = true;
    }
  }, onError: (Object _) {})..pause();
  socket.add(
    MessageFraming.frame(
      RunnerMessage(
        hello: RunnerHello(protocolVersion: 1, pid: 7),
      ).writeToBuffer(),
    ),
  );
  final frame = MessageFraming.frame(
    RunnerMessage(
      frame: Frame(
        sequence: Int64(1),
        width: 256,
        height: 256,
        rowBytes: 1024,
        pixels: Uint8List(256 * 1024),
      ),
    ).writeToBuffer(),
  );
  for (var sent = 0; sent < _flood; sent += frame.length) {
    socket.add(frame);
  }
  report.send('sent');
  await commands.first;
  // Long enough for a reset, had the client closed with these unread.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  reading.resume();
  await Future<void>.delayed(const Duration(milliseconds: 300));
  report.send(shutdown);
  socket.destroy();
  await server.close();
}

const _flood = 4 << 20;

void main() {
  test(
    'a Shutdown reaches a runner whose frames the client left unread',
    () async {
      // Windows resets a connection closed with bytes unread, and the reset
      // throws away what the runner had not read yet. A runner busy writing
      // frames reads late, so close must read until the runner hangs up.
      final temp = Directory.systemTemp.createTempSync('raccoon_close');
      addTearDown(() => temp.deleteSync(recursive: true));
      final path = p.join(temp.path, 'runner.sock');
      final reports = ReceivePort();
      final messages = StreamIterator(reports);
      await Isolate.spawn(_busyRunner, (path, reports.sendPort));
      await messages.moveNext();
      final commands = messages.current as SendPort;
      while (!File(path).existsSync()) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final client = await RunnerClient.connect(UnixSocketEndpoint(path));
      await messages.moveNext();
      expect(messages.current, 'sent');
      // Blocked, as a client busy elsewhere is: the frames pile up unread.
      sleep(const Duration(milliseconds: 300));
      client.shutdown();
      commands.send('closing');
      await client.close();

      await messages.moveNext();
      expect(messages.current, isTrue, reason: 'the runner saw the Shutdown');
      reports.close();
    },
  );

  test('a write to a runner that is gone does nothing', () async {
    // The runner exits while the client, busy, hasn't seen it hang up yet:
    // the next write hits a closed socket, Broken pipe (#90).
    final temp = Directory.systemTemp.createTempSync('raccoon_gone');
    addTearDown(() => temp.deleteSync(recursive: true));
    final path = p.join(temp.path, 'runner.sock');
    final reports = ReceivePort();
    final messages = StreamIterator(reports);
    await Isolate.spawn(_exitingRunner, (path, reports.sendPort));
    await messages.moveNext();
    final commands = messages.current as SendPort;
    while (!File(path).existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    final client = await RunnerClient.connect(UnixSocketEndpoint(path));
    // As a host listens: an error here would go uncaught and fail the test.
    client.messages.listen((_) {});
    await client.hello.timeout(const Duration(seconds: 5));
    commands.send('exit');
    // Busy while the runner exits: its hang-up waits in the queue, unseen.
    sleep(const Duration(milliseconds: 300));
    client
      ..shutdown()
      ..resize(100, 100, 1);
    await client.closed.timeout(const Duration(seconds: 5));
    await client.close();
    reports.close();
  });
}

/// A runner stand-in that says hello, then exits when told, in an isolate
/// of its own so it does while the test's isolate is blocked.
Future<void> _exitingRunner((String, SendPort) args) async {
  final (path, report) = args;
  final commands = ReceivePort();
  report.send(commands.sendPort);
  final server = await ServerSocket.bind(
    InternetAddress(path, type: InternetAddressType.unix),
    0,
  );
  final socket = await server.first;
  socket.done.ignore();
  socket.listen((_) {}, onError: (Object _) {});
  socket.add(
    MessageFraming.frame(
      RunnerMessage(
        hello: RunnerHello(protocolVersion: 1, pid: 7),
      ).writeToBuffer(),
    ),
  );
  await commands.first;
  socket.destroy();
  await server.close();
  commands.close();
}

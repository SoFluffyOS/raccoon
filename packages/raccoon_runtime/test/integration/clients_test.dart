// Drives the real runner: clients: who holds a run, how frames reach one that
// reads late or not at all, inline or through shared buffers. Skipped when the
// runner or its inputs are not built; see
// native/raccoon_runner/tool/render_example.sh. What the files share is in
// test/support/runner_fixture.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:raccoon/raccoon.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

import '../support/runner_fixture.dart';

// The fixture's helpers, by the names these tests have always used.
const _expectExit = expectExit;
const _exitCode = runnerExitCode;

void main() {
  final RunnerFixture(:binary, :assets, :engineDir, :icu, :ready) =
      RunnerFixture();
  test(
    'a later run of the app at the same socket stops the one before it',
    () async {
      // #324: the newer run wins, as an IDE's re-run does. The older runner
      // goes cleanly, and leaves the newer one's socket file where it is.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final socket = p.join(temp.path, 'runner.sock');
      Future<(Process, List<String>)> serve() async {
        final process = await Process.start(binary ?? '', [
          'serve',
          '--engine-dir',
          engineDir ?? '',
          '--assets',
          assets,
          '--icu',
          icu ?? '',
          '--socket',
          socket,
        ]);
        final errors = <String>[];
        process.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(errors.add);
        final listening = Completer<void>();
        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              if (line.contains('listening on') && !listening.isCompleted) {
                listening.complete();
              }
            });
        await Future.any([
          listening.future,
          process.exitCode.then((code) => fail('exited $code: $errors')),
        ]).timeout(const Duration(seconds: 15));
        return (process, errors);
      }

      final (older, olderErrors) = await serve();
      Process? newer;
      try {
        // Before, both said they listened and the older ran on, unreachable.
        final (started, _) = await serve();
        newer = started;
        final code = await older.exitCode.timeout(const Duration(seconds: 5));
        expect(code, 0, reason: olderErrors.join('\n'));
        expect(olderErrors.join('\n'), contains('a later run took'));
        // The newer one is the one a client reaches.
        expect(File(socket).existsSync() || Link(socket).existsSync(), isTrue);
        final client = await RunnerClient.connect(UnixSocketEndpoint(socket));
        await client.hello.timeout(const Duration(seconds: 10));
        client.shutdown();
        await client.close();
        expect(await newer.exitCode.timeout(const Duration(seconds: 10)), 0);
      } finally {
        older.kill();
        newer?.kill();
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'a claim from a host gone as it is let in leaves the runner whole for the '
    'next',
    () async {
      // raccoon#285: the runner's hello to it fails and closes it; what it
      // sent must not be read, nor its place in the stream kept.
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
      final holder = await RunnerClient.connect(endpoint, yields: true);
      RunnerClient? next;
      var nextClosed = false;
      try {
        await holder.hello.timeout(const Duration(seconds: 10));
        await holder.frames.first.timeout(const Duration(seconds: 15));
        // A claim that reads nothing back: on Linux the runner's hello to it
        // fails.
        final claimer = await Socket.connect(
          InternetAddress(endpoint.path, type: InternetAddressType.unix),
          0,
        );
        claimer.add(
          MessageFraming.frame(
            ClientMessage(
              hello: ClientHello(
                protocolVersion: 1,
                claims: true,
                clientName: 'x' * 2000,
              ),
            ).writeToBuffer(),
          ),
        );
        await claimer.flush();
        await claimer.close();
        claimer.destroy();
        await holder.closed.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        // The next client has the runner, its messages read whole.
        next = await RunnerClient.connect(endpoint);
        unawaited(next.closed.then((_) => nextClosed = true));
        await next.hello.timeout(const Duration(seconds: 10));
        await next.frames.first.timeout(const Duration(seconds: 15));
      } finally {
        await holder.close();
        final client = next;
        if (client != null) {
          // A runner that hung up on it hears no Shutdown: said, should it
          // not exit.
          printOnFailure(
            'the next client was closed before Shutdown: $nextClosed',
          );
          client.shutdown();
          await client.close();
        }
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );
  // raccoon#309: a claim whose sender hung up before the runner read it
  // came in one read with the hang-up, and was dropped with it; on a slow
  // machine the holder kept the run. The runner is stopped while the claim
  // comes and goes, so it reads both at once, every time.
  test(
    'a claim read together with its sender\'s hang-up still takes the run',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      addTearDown(() => temp.deleteSync(recursive: true));
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
      final holder = await RunnerClient.connect(endpoint, yields: true);
      RunnerClient? next;
      try {
        await holder.hello.timeout(const Duration(seconds: 10));
        await holder.frames.first.timeout(const Duration(seconds: 15));
        expect(Process.killPid(runner.pid, ProcessSignal.sigstop), isTrue);
        try {
          final claimer = await Socket.connect(
            InternetAddress(endpoint.path, type: InternetAddressType.unix),
            0,
          );
          claimer.add(
            MessageFraming.frame(
              ClientMessage(
                hello: ClientHello(protocolVersion: 1, claims: true),
              ).writeToBuffer(),
            ),
          );
          await claimer.flush();
          await claimer.close();
          claimer.destroy();
        } finally {
          Process.killPid(runner.pid, ProcessSignal.sigcont);
        }
        await holder.closed.timeout(const Duration(seconds: 5));
        next = await RunnerClient.connect(endpoint);
        await next.hello.timeout(const Duration(seconds: 10));
        await next.frames.first.timeout(const Duration(seconds: 15));
      } finally {
        await holder.close();
        if (next case final client?) {
          client.shutdown();
          await client.close();
        }
        await _expectExit(runner);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'stopping a process is a signal',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'a host that claims a run takes it from one that yields; nobody else does',
    () async {
      // raccoon#281.
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
      Future<Object?> outcome(RunnerClient client) async {
        try {
          await client.hello.timeout(const Duration(seconds: 10));
          return 'hello';
        } on Object catch (error) {
          return error;
        }
      }

      final holder = await RunnerClient.connect(endpoint, yields: true);
      RunnerClient? owner;
      try {
        expect(await outcome(holder), 'hello');
        await holder.frames.first.timeout(const Duration(seconds: 15));
        // Another that doesn't claim it: Busy, the holder stays.
        final other = await RunnerClient.connect(endpoint);
        expect(await outcome(other), isA<RunnerBusy>());
        await other.close();
        // One that connects and says nothing holds the waiting place for a
        // second at most.
        final silent = await Socket.connect(
          InternetAddress(endpoint.path, type: InternetAddressType.unix),
          0,
        );
        final heard = MessageUnframer();
        final told = Completer<RunnerMessage>();
        silent.listen((bytes) {
          for (final payload in heard.add(bytes)) {
            if (!told.isCompleted) {
              told.complete(RunnerMessage.fromBuffer(payload));
            }
          }
        }, onError: (_) {});
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        // Its own host claims it: the holder goes, the owner has it.
        owner = await RunnerClient.connect(endpoint, claims: true);
        expect(await outcome(owner), 'hello');
        await holder.closed.timeout(const Duration(seconds: 5));
        // The silent one was told who has the runner, not just hung up on.
        final said = await told.future.timeout(const Duration(seconds: 5));
        expect(said.hasBusy(), isTrue);
        await owner.frames.first.timeout(const Duration(seconds: 15));
        // A claim against a holder that doesn't yield: Busy, as before.
        final late = await RunnerClient.connect(endpoint, claims: true);
        expect(await outcome(late), isA<RunnerBusy>());
        await late.close();
        silent.destroy();
      } finally {
        await holder.close();
        final client = owner;
        if (client != null) {
          client.shutdown();
          await client.close();
        }
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'a second client is told who has the runner, then hung up on',
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
      final first = await RunnerClient.connect(endpoint);
      try {
        await first.hello.timeout(const Duration(seconds: 10));
        // The runner says hello before it reads the client's; give it time
        // to learn the first client's pid.
        await first.frames.first.timeout(const Duration(seconds: 15));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        Object? failure;
        RunnerClient? second;
        try {
          second = await RunnerClient.connect(endpoint);
          await second.hello.timeout(const Duration(seconds: 5));
        } on Object catch (error) {
          failure = error;
        }
        expect(failure, isA<RunnerBusy>().having((b) => b.pid, 'pid', pid));
        await second?.closed.timeout(const Duration(seconds: 5));
        await second?.close();
      } finally {
        first.shutdown();
        await first.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );
  // #138: the runner kept the last client's pid after it left, and told a
  // newcomer that one held it.
  test(
    'a client that left is not named to a newcomer',
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
      final address = InternetAddress(
        endpoint.path,
        type: InternetAddressType.unix,
      );
      Socket? quiet;
      try {
        final first = await RunnerClient.connect(endpoint);
        await first.frames.first.timeout(const Duration(seconds: 15));
        await first.close();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        // Holds the runner without a hello yet.
        quiet = await Socket.connect(address, 0);
        quiet.listen(null);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        Object? failure;
        RunnerClient? newcomer;
        try {
          newcomer = await RunnerClient.connect(endpoint);
          await newcomer.hello.timeout(const Duration(seconds: 5));
        } on Object catch (error) {
          failure = error;
        }
        expect(failure, isA<RunnerBusy>().having((b) => b.pid, 'pid', 0));
        await newcomer?.close();
      } finally {
        quiet?.destroy();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final last = await RunnerClient.connect(endpoint);
        await last.hello.timeout(const Duration(seconds: 5));
        last.shutdown();
        await last.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'a raw socket stands in for a client',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
  // #145: a client whose set came short says hello again without shared
  // buffers; the runner sends it frames inline from then on.
  test(
    'a hello without shared buffers turns the runner to inline frames',
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
        final message = socket.readMessage();
        if (message == null) return;
        for (final control in message.controlMessages) {
          for (final handle in control.extractHandles()) {
            handle.toFile().closeSync();
          }
        }
        for (final payload in unframer.add(message.data)) {
          messages.add(RunnerMessage.fromBuffer(payload));
        }
      });
      void send(ClientMessage message) =>
          socket.write(MessageFraming.frame(message.writeToBuffer()));
      try {
        final set = messages.stream.firstWhere((m) => m.hasSharedBuffers());
        send(
          ClientMessage(
            hello: ClientHello(protocolVersion: 1, pid: 1, sharedBuffers: true),
          ),
        );
        await set.timeout(const Duration(seconds: 15));

        final inline = messages.stream.firstWhere(
          (m) => m.hasFrame() && !m.frame.inSharedBuffer,
        );
        send(
          ClientMessage(
            hello: ClientHello(
              protocolVersion: 1,
              pid: 1,
              sharedBuffers: false,
            ),
          ),
        );
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
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'shared buffers are Unix sockets',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'a client that reuses its pixel buffers gets the frames all the same',
    () async {
      // With reusePixels, frames from shared buffers land in three buffers
      // the client keeps, so some of eight frames share their memory.
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
      final client = await RunnerClient.connect(endpoint, reusePixels: true);
      try {
        final shared = await client.frames
            .where(
              (frame) => client.sharedFrames > 0 && frame.pixels.isNotEmpty,
            )
            .skip(2)
            .take(8)
            .toList()
            .timeout(const Duration(seconds: 15));
        expect(shared.last.pixels.any((byte) => byte != 0), isTrue);
        // A mark of its own written into each frame's pixels: frames that
        // share their memory then all show the last mark written there.
        // An inline frame among them keeps its own; without reuse all do.
        for (var i = 0; i < shared.length; i++) {
          (shared[i].pixels as Uint8List)[0] = i + 1;
        }
        final marks = {for (final frame in shared) frame.pixels[0]};
        expect(marks.length, lessThan(shared.length));
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'shared buffers are Unix sockets',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
  // #146: a single message past the unread limit, a 4K frame inline, let
  // a client go that was reading.
  test(
    'a client reading a frame larger than the unread limit keeps its place',
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
          width: 3840,
          height: 2400,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      try {
        // About 37 MB, inline: the first frame comes before shared buffers.
        final frame = await client.frames.first.timeout(
          const Duration(seconds: 20),
        );
        expect(frame.width, 3840);
        var letGo = false;
        unawaited(client.closed.then((_) => letGo = true));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(letGo, isFalse);
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
}

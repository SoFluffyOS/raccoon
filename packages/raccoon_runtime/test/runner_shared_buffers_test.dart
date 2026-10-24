// Descriptors travel on Unix sockets only.
@TestOn('!windows')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:path/path.dart' as p;
import 'package:raccoon/raccoon.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

void main() {
  // #135: a release named only its index, so one meant for a set since
  // replaced freed the same index in the new set.
  test('a shared buffer goes back with its set\'s generation', () async {
    final temp = Directory.systemTemp.createTempSync('raccoon_shared');
    addTearDown(() => temp.deleteSync(recursive: true));
    final path = p.join(temp.path, 'app.sock');
    final server = await RawServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    addTearDown(server.close);
    final buffers = [
      for (var i = 0; i < 2; i++)
        (File(p.join(temp.path, 'buffer$i'))
          ..writeAsBytesSync([9, 8, 7, 6])).openSync(mode: FileMode.append),
    ];
    final releases = StreamController<ReleaseBuffer>();
    server.listen((socket) {
      final unframer = MessageUnframer();
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final bytes = socket.read();
        if (bytes == null) return;
        for (final payload in unframer.add(bytes)) {
          final message = ClientMessage.fromBuffer(payload);
          if (message.hasReleaseBuffer()) releases.add(message.releaseBuffer);
        }
      });
      socket.write(
        MessageFraming.frame(
          RunnerMessage(hello: RunnerHello(protocolVersion: 1)).writeToBuffer(),
        ),
      );
      socket.sendMessage(
        [
          SocketControlMessage.fromHandles([
            for (final buffer in buffers) ResourceHandle.fromFile(buffer),
          ]),
        ],
        MessageFraming.frame(
          RunnerMessage(
            sharedBuffers: SharedBuffers(
              count: 2,
              size: Int64(4),
              generation: 5,
            ),
          ).writeToBuffer(),
        ),
      );
      socket.write(
        MessageFraming.frame(
          RunnerMessage(
            frame: Frame(
              sequence: Int64(1),
              width: 1,
              height: 1,
              rowBytes: 4,
              inSharedBuffer: true,
              bufferIndex: 0,
            ),
          ).writeToBuffer(),
        ),
      );
    });

    final client = await RunnerClient.connect(UnixSocketEndpoint(path));
    addTearDown(client.close);
    final frame = await client.frames.first.timeout(const Duration(seconds: 5));
    expect(frame.pixels, Uint8List.fromList([9, 8, 7, 6]));
    final release = await releases.stream.first.timeout(
      const Duration(seconds: 5),
    );
    expect(release.index, 0);
    expect(release.generation, 0);
    expect(release.sharedGeneration, 5);
    for (final buffer in buffers) {
      buffer.closeSync();
    }
  });

  // #145: a set that came short of its descriptors left the client with no
  // buffers while the runner went on filling them.
  // #148: only a runner that numbers its sets drops its pool for that
  // hello; an older one is left to the next resize, as before.
  for (final generation in [1, 0]) {
    test(
      'a set that comes short, of generation $generation, '
      '${generation == 0 ? 'waits for a resize' : 'asks for frames inline'}',
      () async {
        final temp = Directory.systemTemp.createTempSync('raccoon_short');
        addTearDown(() => temp.deleteSync(recursive: true));
        final path = p.join(temp.path, 'app.sock');
        final server = await RawServerSocket.bind(
          InternetAddress(path, type: InternetAddressType.unix),
          0,
        );
        addTearDown(server.close);
        final only = (File(p.join(temp.path, 'buffer0'))
          ..writeAsBytesSync([0])).openSync(mode: FileMode.append);
        addTearDown(only.closeSync);
        final hellos = StreamController<ClientHello>();
        server.listen((socket) {
          final unframer = MessageUnframer();
          socket.listen((event) {
            if (event != RawSocketEvent.read) return;
            final bytes = socket.read();
            if (bytes == null) return;
            for (final payload in unframer.add(bytes)) {
              final message = ClientMessage.fromBuffer(payload);
              if (message.hasHello()) hellos.add(message.hello);
            }
          });
          // Two buffers named, one descriptor along.
          socket.sendMessage(
            [
              SocketControlMessage.fromHandles([ResourceHandle.fromFile(only)]),
            ],
            MessageFraming.frame(
              RunnerMessage(
                sharedBuffers: SharedBuffers(
                  count: 2,
                  size: Int64(4),
                  generation: generation,
                ),
              ).writeToBuffer(),
            ),
          );
        });

        final client = await RunnerClient.connect(UnixSocketEndpoint(path));
        addTearDown(client.close);
        final said = <ClientHello>[];
        hellos.stream.listen(said.add);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(said.first.sharedBuffers, isTrue);
        expect(said, hasLength(generation == 0 ? 1 : 2));
        if (generation != 0) expect(said.last.sharedBuffers, isFalse);
      },
    );
  }
}

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

Future<ServerSocket> _bind(String path) =>
    ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('raccoon_disc'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('resolves the socket directory for the host', () {
    final linux = RunnerDiscovery.forHost(
      operatingSystem: 'linux',
      environment: {'XDG_RUNTIME_DIR': '/run/user/7'},
      temporaryDirectory: '/tmp',
    );
    expect(linux.directory, '/run/user/7/raccoon');
    expect(linux.pollInterval, isNull, reason: 'inotify sees sockets');

    final macos = RunnerDiscovery.forHost(
      operatingSystem: 'macos',
      environment: const {},
      temporaryDirectory: '/var/folders/x/T',
    );
    expect(macos.directory, '/var/folders/x/T/raccoon');
    expect(macos.pollInterval, isNotNull, reason: 'FSEvents misses sockets');

    final windows = RunnerDiscovery.forHost(
      operatingSystem: 'windows',
      environment: const {},
      temporaryDirectory: r'C:\Users\me\AppData\Local\Temp',
    );
    expect(windows.directory, r'C:\Users\me\AppData\Local\Temp\raccoon');
    expect(
      windows.pollInterval,
      isNull,
      reason: 'directory changes include sockets',
    );
  });

  // #118: a key too long for a socket path runs under a shorter socket
  // name, with the key in a .name file beside it.
  test('a socket directory that cannot be made fails the watch, as a stream '
      'error', () async {
    // A file where its parent should be.
    final blocker = File(p.join(temp.path, 'blocked'))..writeAsStringSync('');
    final discovery = RunnerDiscovery(p.join(blocker.path, 'raccoon'));
    await expectLater(
      discovery.watch(),
      emitsError(isA<FileSystemException>()),
    );
  });

  test('names the app after its .name file when there is one', () async {
    final short = await _bind(p.join(temp.path, 'a_long_name~12345.sock'));
    addTearDown(short.close);
    File(
      p.join(temp.path, 'a_long_name~12345.name'),
    ).writeAsStringSync('a_long_name_that_did_not_fit@phone\n');
    final plain = await _bind(p.join(temp.path, 'hello.sock'));
    addTearDown(plain.close);
    final names = RunnerDiscovery(
      temp.path,
    ).list().map(RunnerDiscovery.appNameOf);
    expect(names, ['a_long_name_that_did_not_fit@phone', 'hello']);
  });

  test('lists sockets only and names the app after the file', () async {
    final discovery = RunnerDiscovery(temp.path);
    File(p.join(temp.path, 'notes.sock')).writeAsStringSync('not a socket');
    final server = await _bind(p.join(temp.path, 'hello.sock'));

    final found = discovery.list();

    expect(found.map(RunnerDiscovery.appNameOf), ['hello']);
    await server.close();
  });

  // Watching through file system events is only sound where they report
  // sockets, which FSEvents on macOS do not; polling works on every host.
  for (final (mode, discovery) in [
    (
      'polling',
      (String dir) =>
          RunnerDiscovery(dir, pollInterval: const Duration(milliseconds: 50)),
    ),
    if (!Platform.isMacOS) ('file system events', RunnerDiscovery.new),
  ]) {
    test('watch reports runners as they appear and go, by $mode', () async {
      final watching = discovery(p.join(temp.path, 'raccoon'));
      final seen = <List<String>>[];
      final subscription = watching
          .watch()
          .map((e) => e.map(RunnerDiscovery.appNameOf).toList())
          .listen(seen.add);
      await _until(() => seen.isNotEmpty);
      expect(seen.first, isEmpty);

      final server = await _bind(p.join(watching.directory, 'app.sock'));
      await _until(() => seen.any((names) => names.contains('app')));

      await server.close();
      // Closing the server removes the socket file on Linux; be sure.
      final socketFile = File(p.join(watching.directory, 'app.sock'));
      if (socketFile.existsSync()) socketFile.deleteSync();
      await _until(() => seen.last.isEmpty);
      expect(seen, hasLength(3), reason: 'one event per change');
      await subscription.cancel();
    });
  }

  // #134: the watch ended when its directory went, so runners started
  // after that never showed.
  test(
    'a watch goes on when its directory is removed',
    () async {
      final watching = RunnerDiscovery(p.join(temp.path, 'raccoon'));
      final seen = <List<String>>[];
      final subscription = watching
          .watch()
          .map((e) => e.map(RunnerDiscovery.appNameOf).toList())
          .listen(seen.add, onDone: () => seen.add(['done']));
      await _until(() => seen.isNotEmpty);
      Directory(watching.directory).deleteSync(recursive: true);
      await _until(() => Directory(watching.directory).existsSync());

      final server = await _bind(p.join(watching.directory, 'app.sock'));
      await _until(() => seen.any((names) => names.contains('app')));
      expect(seen, isNot(contains(['done'])));
      await server.close();
      await subscription.cancel();
    },
    skip: switch (Platform.isMacOS) {
      true => 'macOS polls',
      false => false,
    },
  );

  // #137: a watch that could not be set up, as when Linux runs out of
  // inotify watches, was set up again at once, for good, freezing the host.
  test('a watch that cannot be set up falls back to polling', () async {
    var watches = 0;
    final watching = RunnerDiscovery(
      p.join(temp.path, 'raccoon'),
      watcher: (_) {
        watches++;
        // As the VM's watcher fails: an error, then the end.
        final failed = StreamController<FileSystemEvent>();
        failed
          ..addError(const FileSystemException('inotify limit reached'))
          ..close();
        return failed.stream;
      },
    );
    final seen = <List<String>>[];
    final errors = <Object>[];
    final subscription = watching
        .watch()
        .map((e) => e.map(RunnerDiscovery.appNameOf).toList())
        .listen(seen.add, onError: errors.add);
    await _until(() => seen.isNotEmpty);
    final server = await _bind(p.join(watching.directory, 'app.sock'));
    await _until(() => seen.any((names) => names.contains('app')));
    expect(watches, 1);
    expect(errors, hasLength(1));
    await server.close();
    await subscription.cancel();
  });

  test('a runner bound while the watch starts is seen at once', () async {
    // #230: the directory was listed before the watch began, and Linux and
    // Windows tell only of what changes after: a socket made in between
    // stayed unseen until something else changed.
    final dir = p.join(temp.path, 'raccoon');
    final socket = p.join(dir, 'app.sock');
    final discovery = RunnerDiscovery(
      dir,
      watcher: (_) {
        Process.runSync('python3', [
          '-c',
          'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])',
          socket,
        ]);
        return const Stream<FileSystemEvent>.empty();
      },
    );

    final first = await discovery.watch().first;

    expect(first.map((endpoint) => endpoint.path), [socket]);
  }, testOn: '!windows');
}

/// Polls [condition] until it holds, failing after five seconds.
Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met in time');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

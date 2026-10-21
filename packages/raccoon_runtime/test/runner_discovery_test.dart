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
    if (Platform.isLinux) ('file system events', RunnerDiscovery.new),
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
}

/// Polls [condition] until it holds, failing after five seconds.
Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met in time');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

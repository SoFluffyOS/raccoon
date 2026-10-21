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
    expect(
      RunnerDiscovery.forHost({
        'XDG_RUNTIME_DIR': '/run/user/7',
      }, '/tmp').directory,
      '/run/user/7/raccoon',
    );
  });

  test('lists sockets only and names the app after the file', () async {
    final discovery = RunnerDiscovery(temp.path);
    File(p.join(temp.path, 'notes.sock')).writeAsStringSync('not a socket');
    final server = await _bind(p.join(temp.path, 'hello.sock'));

    final found = discovery.list();

    expect(found.map(RunnerDiscovery.appNameOf), ['hello']);
    await server.close();
  });

  test('watch reports runners as they appear and go', () async {
    final discovery = RunnerDiscovery(p.join(temp.path, 'raccoon'));
    final updates = discovery.watch().map(
      (e) => e.map(RunnerDiscovery.appNameOf).toList(),
    );
    final seen = <List<String>>[];
    final subscription = updates.listen(seen.add);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final server = await _bind(p.join(discovery.directory, 'app.sock'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await server.close();
    File(p.join(discovery.directory, 'app.sock')).deleteSync();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await subscription.cancel();

    expect(seen.first, isEmpty);
    expect(seen, contains(['app']));
    expect(seen.last, isEmpty);
  });
}

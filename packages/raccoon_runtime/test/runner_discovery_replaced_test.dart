import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('a runner replaced under the same path is a change', () async {
    final temp = Directory.systemTemp.createTempSync('raccoon_discovery');
    // As the device helper leaves a socket directory: Dart makes a temporary
    // one open to others on Linux, which discovery refuses in /tmp.
    if (!Platform.isWindows) Process.runSync('chmod', ['700', temp.path]);
    final discovery = RunnerDiscovery(
      temp.path,
      pollInterval: const Duration(milliseconds: 50),
    );
    final events = <List<UnixSocketEndpoint>>[];
    final subscription = discovery.watch().listen(events.add);
    final path = p.join(temp.path, 'hello.sock');
    Future<ServerSocket> bind() => ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    var server = await bind();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    // Gone and back before the next poll: the same path, a new runner.
    await server.close();
    server = await bind();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await subscription.cancel();
    await server.close();
    temp.deleteSync(recursive: true);
    final withHello = events.where(
      (list) => list.any((endpoint) => endpoint.path == path),
    );
    expect(withHello.length, greaterThanOrEqualTo(2));
  });
}

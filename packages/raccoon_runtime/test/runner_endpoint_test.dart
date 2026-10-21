import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('linux uses the XDG runtime directory', () {
    final endpoint = RunnerEndpoint.forHost(
      operatingSystem: 'linux',
      environment: {'XDG_RUNTIME_DIR': '/run/user/1000'},
      temporaryDirectory: '/tmp',
    );

    expect(endpoint, isA<UnixSocketEndpoint>());
    expect(endpoint.uri, 'unix:/run/user/1000/raccoon/runner.sock');
  });

  test('linux falls back to the temporary directory', () {
    final endpoint = RunnerEndpoint.forHost(
      operatingSystem: 'linux',
      environment: {'XDG_RUNTIME_DIR': ''},
      temporaryDirectory: '/tmp',
    );

    expect(endpoint.uri, 'unix:/tmp/raccoon/runner.sock');
  });

  test('macos uses the temporary directory', () {
    final endpoint = RunnerEndpoint.forHost(
      operatingSystem: 'macos',
      environment: const {},
      temporaryDirectory: '/var/folders/x/T',
    );

    expect(endpoint.uri, 'unix:/var/folders/x/T/raccoon/runner.sock');
  });

  test('windows uses loopback TCP with the default port', () {
    final endpoint = RunnerEndpoint.forHost(
      operatingSystem: 'windows',
      environment: const {},
      temporaryDirectory: r'C:\Temp',
    );

    expect(endpoint, isA<LoopbackTcpEndpoint>());
    expect(endpoint.uri, 'tcp:127.0.0.1:${LoopbackTcpEndpoint.defaultPort}');
  });

  test('windows honours RACCOON_PORT', () {
    final endpoint = RunnerEndpoint.forHost(
      operatingSystem: 'windows',
      environment: {'RACCOON_PORT': '5000'},
      temporaryDirectory: r'C:\Temp',
    );

    expect(endpoint.uri, 'tcp:127.0.0.1:5000');
  });
}

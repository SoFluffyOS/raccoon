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

  test('windows uses a Unix socket in the temporary directory', () {
    final endpoint = RunnerEndpoint.forHost(
      operatingSystem: 'windows',
      environment: {'XDG_RUNTIME_DIR': '/run/user/1000'},
      temporaryDirectory: r'C:\Users\me\AppData\Local\Temp',
    );

    expect(endpoint, isA<UnixSocketEndpoint>());
    expect(
      endpoint.uri,
      r'unix:C:\Users\me\AppData\Local\Temp\raccoon\runner.sock',
    );
  });
}

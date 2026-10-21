import 'package:raccoon/raccoon.dart';
import 'package:test/test.dart';

void main() {
  test('is absent without the endpoint variable', () {
    const raccoon = Raccoon.withEnvironment({});

    expect(raccoon.isPresent, isFalse);
    expect(raccoon.endpoint, isNull);
  });

  test('is present with an endpoint', () {
    const endpoint = 'unix:/run/user/1000/raccoon/runner.sock';
    const raccoon = Raccoon.withEnvironment({
      RaccoonProtocol.endpointVariable: endpoint,
    });

    expect(raccoon.isPresent, isTrue);
    expect(raccoon.endpoint, endpoint);
  });

  test('treats an empty endpoint as absent', () {
    const raccoon = Raccoon.withEnvironment({
      RaccoonProtocol.endpointVariable: '',
    });

    expect(raccoon.isPresent, isFalse);
  });
}

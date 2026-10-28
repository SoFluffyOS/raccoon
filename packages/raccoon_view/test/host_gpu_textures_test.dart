import 'package:flutter_test/flutter_test.dart';
import 'package:raccoon_view/raccoon_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // raccoon#239: a host's hot restart keeps the native plugin and the
  // textures the old views made; the first texture of a new isolate lets
  // them go first, once.
  test('the first texture of an isolate resets the plugin, once', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannelGpuTextures.channel, (
          call,
        ) async {
          calls.add(call.method);
          return call.method == 'create' ? calls.length : null;
        });
    const textures = MethodChannelGpuTextures(bottomUp: false);

    await textures.create();
    await textures.create();

    expect(calls, ['reset', 'create', 'create']);
  });
}

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raccoon_view/raccoon_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <String>[];
  Object? Function(String method) answer = (_) => null;

  setUp(() {
    MethodChannelGpuTextures.forgetReset();
    calls.clear();
    answer = (_) => null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannelGpuTextures.channel, (
          call,
        ) async {
          calls.add(call.method);
          if (call.method == 'create') return calls.length;
          final answered = answer(call.method);
          if (answered is Future) return await answered;
          return answered;
        });
  });

  tearDown(() {
    MethodChannelGpuTextures.resetTimeout = const Duration(seconds: 2);
  });

  // raccoon#239: a host's hot restart keeps the native plugin and the
  // textures the old views made; the first texture of a new isolate lets
  // them go first, once.
  test('the first texture of an isolate resets the plugin, once', () async {
    const textures = MethodChannelGpuTextures(bottomUp: false);

    await textures.create();
    await textures.create();

    expect(calls, ['reset', 'create', 'create']);
  });

  test('a reset that fails holds no texture back', () async {
    answer =
        (method) => switch (method) {
          'reset' => throw PlatformException(code: 'gone'),
          _ => null,
        };
    const textures = MethodChannelGpuTextures(bottomUp: false);

    expect(await textures.create(), 2);
    expect(calls, ['reset', 'create']);
  });

  test('a reset that never answers holds the first texture back only so '
      'long', () async {
    MethodChannelGpuTextures.resetTimeout = const Duration(milliseconds: 100);
    final never = Completer<void>();
    answer =
        (method) => switch (method) {
          'reset' => never.future,
          _ => null,
        };
    const textures = MethodChannelGpuTextures(bottomUp: false);

    final id = await textures.create().timeout(const Duration(seconds: 2));
    expect(id, 2);
    expect(calls, ['reset', 'create']);
  });
}

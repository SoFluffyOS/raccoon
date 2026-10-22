import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raccoon_view/raccoon_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = JSONMethodCodec();

  Uint8List encode(String method, [Object? arguments]) {
    final data = codec.encodeMethodCall(MethodCall(method, arguments));
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      return switch (call.method) {
        'Clipboard.getData' => {'text': 'from the ide'},
        'Clipboard.setData' => null,
        _ => throw MissingPluginException(),
      };
    });
  });

  test('answers Clipboard.getData with the ide clipboard', () async {
    const channels = IdePlatformChannels();

    final reply = await channels.handlePlatform(
      encode('Clipboard.getData', 'text/plain'),
    );

    expect(reply, isNotNull);
    final decoded = codec.decodeEnvelope(
      ByteData.sublistView(reply ?? Uint8List(0)),
    );
    expect(decoded, {'text': 'from the ide'});
  });

  test('accepts sounds and leaves unknown methods to no plugin', () async {
    const channels = IdePlatformChannels();

    expect(
      await channels.handlePlatform(
        encode('SystemSound.play', 'SystemSoundType.click'),
      ),
      isNotNull,
    );
    expect(await channels.handlePlatform(encode('Something.else')), isNull);
  });
}

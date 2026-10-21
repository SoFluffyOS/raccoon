import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raccoon_view/raccoon_view.dart';

void main() {
  const codec = StandardMessageCodec();

  Uint8List request(String url) {
    final data = codec.encodeMessage([url]);
    return data?.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes) ??
        Uint8List(0);
  }

  Object? reply(Uint8List? bytes) =>
      codec.decodeMessage(ByteData.sublistView(bytes ?? Uint8List(0)));

  test('canLaunch answers with the launcher', () async {
    final asked = <Uri>[];
    final channels = IdeUrlLauncherChannels(
      canLaunch: (url) async {
        asked.add(url);
        return url.scheme == 'https';
      },
    );

    expect(
      reply(await channels.handleCanLaunch(request('https://lumide.dev'))),
      [true],
    );
    expect(reply(await channels.handleCanLaunch(request('gopher://x'))), [
      false,
    ]);
    expect(asked.map((u) => u.scheme), ['https', 'gopher']);
  });

  test('launch replies null on success and a message on failure', () async {
    final channels = IdeUrlLauncherChannels(
      launch: (url) async => url.host == 'lumide.dev',
    );

    expect(reply(await channels.handleLaunch(request('https://lumide.dev'))), [
      null,
    ]);
    expect(reply(await channels.handleLaunch(request('https://nope.test'))), [
      'could not launch https://nope.test',
    ]);
  });
}

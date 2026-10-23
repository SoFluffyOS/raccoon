import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raccoon_view/raccoon_view.dart';
import 'package:raccoon_view/src/url_launcher_macos_codec.dart';

void main() {
  const codec = StandardMessageCodec();
  const macosCodec = UrlLauncherMacosCodec();

  Uint8List request(String url) {
    final data = codec.encodeMessage([url]);
    return data?.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes) ??
        Uint8List(0);
  }

  Object? reply(Uint8List? bytes) =>
      codec.decodeMessage(ByteData.sublistView(bytes ?? Uint8List(0)));

  (bool, bool) macosReply(Uint8List? bytes) {
    final decoded = macosCodec.decodeMessage(
      ByteData.sublistView(bytes ?? Uint8List(0)),
    );
    final result = (decoded as List).single as UrlLauncherMacosResult;
    return (result.value, result.invalidUrl);
  }

  test('linux canLaunch answers with the launcher', () async {
    final asked = <Uri>[];
    final channels = IdeUrlLauncherChannels(
      canLaunch: (url) async {
        asked.add(url);
        return url.scheme == 'https';
      },
    );

    expect(
      reply(await channels.handleLinuxCanLaunch(request('https://lumide.dev'))),
      [true],
    );
    expect(reply(await channels.handleLinuxCanLaunch(request('gopher://x'))), [
      false,
    ]);
    expect(asked.map((u) => u.scheme), ['https', 'gopher']);
  });

  test(
    'linux launch replies null on success and a message on failure',
    () async {
      final channels = IdeUrlLauncherChannels(
        launch: (url) async => url.host == 'lumide.dev',
      );

      expect(
        reply(await channels.handleLinuxLaunch(request('https://lumide.dev'))),
        [null],
      );
      expect(
        reply(await channels.handleLinuxLaunch(request('https://nope.test'))),
        ['could not launch https://nope.test'],
      );
    },
  );

  test('windows answers a bool for both, and an error for no url', () async {
    final channels = IdeUrlLauncherChannels(
      canLaunch: (url) async => url.scheme == 'https',
      launch: (url) async => url.host == 'lumide.dev',
    );

    expect(
      reply(
        await channels.handleWindowsCanLaunch(request('https://lumide.dev')),
      ),
      [true],
    );
    expect(
      reply(await channels.handleWindowsCanLaunch(request('gopher://x'))),
      [false],
    );
    expect(
      reply(await channels.handleWindowsLaunch(request('https://lumide.dev'))),
      [true],
    );
    expect(
      reply(await channels.handleWindowsLaunch(request('https://nope.test'))),
      [false],
    );
    expect(
      reply(await channels.handleWindowsLaunch(request('::not a url::'))),
      ['bad-url', 'not a url', null],
    );
  });

  test("macos replies with the plugin's result type", () async {
    final channels = IdeUrlLauncherChannels(
      canLaunch: (url) async => url.scheme == 'https',
      launch: (url) async => url.host == 'lumide.dev',
    );

    expect(
      macosReply(
        await channels.handleMacosCanLaunch(request('https://lumide.dev')),
      ),
      (true, false),
    );
    expect(
      macosReply(await channels.handleMacosCanLaunch(request('gopher://x'))),
      (false, false),
    );
    expect(
      macosReply(
        await channels.handleMacosLaunch(request('https://lumide.dev')),
      ),
      (true, false),
    );
    expect(
      macosReply(
        await channels.handleMacosLaunch(request('https://nope.test')),
      ),
      (false, false),
    );
  });

  test('macos marks a request that is not a url', () async {
    final channels = IdeUrlLauncherChannels(launch: (_) async => true);

    expect(
      macosReply(await channels.handleMacosLaunch(request('::not a url::'))),
      (false, true),
    );
  });

  test("the macos codec writes the plugin's type tags", () {
    final bytes = macosCodec.encodeMessage([
      const UrlLauncherMacosResult(false, invalidUrl: true),
    ]);
    final list = bytes?.buffer.asUint8List(
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );

    // A one-element list; the result tag and its two-element list: false,
    // then the error tag with the enum index 0 as a 32-bit int.
    expect(list, [12, 1, 130, 12, 2, 2, 129, 3, 0, 0, 0, 0]);
  });
}

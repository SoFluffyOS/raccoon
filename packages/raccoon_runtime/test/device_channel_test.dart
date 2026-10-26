import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

void main() {
  Future<Object?> ask(DeviceChannel channel, Object? view) async {
    final reply = await channel.answer(
      Uint8List.fromList(utf8.encode(jsonEncode({'view': view}))),
    );
    return reply == null ? null : jsonDecode(utf8.decode(reply));
  }

  test('each view is answered with its profile, or the fallback', () async {
    final channel = DeviceChannel();
    expect(await ask(channel, 0), isNull);
    channel
      ..fallback = const DeviceProfile(platform: 'android')
      ..set(
        1,
        const DeviceProfile(
          padding: (top: 47, right: 0, bottom: 34, left: 0),
          platform: 'iOS',
        ),
      );
    expect(await ask(channel, 1), {
      'padding': [47, 0, 34, 0],
      'platform': 'iOS',
    });
    expect(await ask(channel, 0), {
      'padding': [0, 0, 0, 0],
      'platform': 'android',
    });
    channel.set(1, null);
    expect((await ask(channel, 1) as Map?)?['platform'], 'android');
  });

  test('an ask that is not JSON gets no answer', () async {
    final channel = DeviceChannel()..fallback = const DeviceProfile();
    expect(await channel.answer(Uint8List.fromList([0xff])), isNull);
  });

  test('the entry asks for its device, with views or without', () {
    final project = Directory.systemTemp.createTempSync('raccoon_entry');
    addTearDown(() => project.deleteSync(recursive: true));
    File(
      p.join(project.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: wonders\n');
    final entry = RaccoonEntrypoint.write(project.path)!;
    expect(entry, p.join(project.path, '.dart_tool', 'raccoon', 'main.dart'));
    final source = File(entry).readAsStringSync();
    expect(source, contains("'raccoon/device'"));
    expect(source, contains('debugDefaultTargetPlatformOverride'));
    expect(source, isNot(contains('ViewCollection')));
    final views =
        File(
          RaccoonEntrypoint.write(project.path, views: true)!,
        ).readAsStringSync();
    expect(views, contains('ViewCollection'));
    expect(views, contains('_RaccoonDevice(child: widget.child)'));
  });
}

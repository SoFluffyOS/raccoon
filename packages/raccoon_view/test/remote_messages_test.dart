import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raccoon_view/raccoon_view.dart';

void main() {
  const codec = StandardMethodCodec();

  test('a message in front carries its notification and data', () {
    final call = codec.decodeMethodCall(
      ByteData.sublistView(
        RemoteMessages.encode(
          title: 'Hello',
          body: 'From Raccoon',
          data: {'route': '/inbox'},
          sentTime: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
      ),
    );
    expect(call.method, 'Messaging#onMessage');
    expect(call.arguments, {
      'messageId': 'raccoon-1000',
      'sentTime': 1000,
      'data': {'route': '/inbox'},
      'notification': {'title': 'Hello', 'body': 'From Raccoon'},
    });
  });

  test('a tapped one opens the app, and data alone has no notification', () {
    final call = codec.decodeMethodCall(
      ByteData.sublistView(
        RemoteMessages.encode(
          data: {'id': '7'},
          opened: true,
          sentTime: DateTime.fromMillisecondsSinceEpoch(5),
        ),
      ),
    );
    expect(call.method, 'Messaging#onMessageOpenedApp');
    expect((call.arguments as Map).containsKey('notification'), isFalse);
  });
}

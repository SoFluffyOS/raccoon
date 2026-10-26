import 'package:flutter/services.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';

/// Sends the app a push notification the way firebase_messaging's native
/// half delivers one (#200): a method call on its channel, which its Dart
/// side turns into a `RemoteMessage`. No Firebase project is involved, and
/// nothing reaches the native side.
abstract final class RemoteMessages {
  /// firebase_messaging's channel, the one its native half calls.
  static const String channel = 'plugins.flutter.io/firebase_messaging';

  static const MethodCodec _codec = StandardMethodCodec();

  /// Sends [client]'s app a message with a notification of [title] and
  /// [body], and [data]. It reaches `FirebaseMessaging.onMessage`, as one
  /// that arrives while the app is in front does, or with [opened]
  /// `onMessageOpenedApp`, as one the user tapped.
  static void send(
    RunnerClient client, {
    String? title,
    String? body,
    Map<String, String> data = const {},
    bool opened = false,
    DateTime? sentTime,
  }) => client.sendToApp(
    channel,
    encode(
      title: title,
      body: body,
      data: data,
      opened: opened,
      sentTime: sentTime ?? DateTime.now(),
    ),
  );

  /// The method call [send] sends, as `RemoteMessage.fromMap` reads it.
  static Uint8List encode({
    String? title,
    String? body,
    Map<String, String> data = const {},
    bool opened = false,
    required DateTime sentTime,
  }) {
    final millis = sentTime.millisecondsSinceEpoch;
    final encoded = _codec.encodeMethodCall(
      MethodCall(
        switch (opened) {
          true => 'Messaging#onMessageOpenedApp',
          false => 'Messaging#onMessage',
        },
        <String, Object?>{
          'messageId': 'raccoon-$millis',
          'sentTime': millis,
          'data': data,
          if (title != null || body != null)
            'notification': <String, Object?>{'title': title, 'body': body},
        },
      ),
    );
    return encoded.buffer.asUint8List(
      encoded.offsetInBytes,
      encoded.lengthInBytes,
    );
  }
}

import 'package:flutter/services.dart';

/// Reads raccoon_static_core's value from another static-library plugin.
abstract final class RaccoonStaticUser {
  static const _channel = MethodChannel('raccoon_static_user');

  static Future<int?> get() => _channel.invokeMethod<int>('get');
}

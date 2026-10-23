import 'package:flutter/services.dart';

/// One value kept by a static-library Windows plugin.
abstract final class RaccoonStaticCore {
  static const _channel = MethodChannel('raccoon_static_core');

  static Future<void> set(int value) => _channel.invokeMethod('set', value);

  static Future<int?> get() => _channel.invokeMethod<int>('get');
}

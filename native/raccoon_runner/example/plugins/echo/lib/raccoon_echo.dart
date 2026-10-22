import 'package:flutter/services.dart';

/// One method, `echo`, answered by the Linux plugin from a GLib idle
/// callback: a round trip through the main loop the host has to pump.
abstract final class RaccoonEcho {
  static const _channel = MethodChannel('raccoon_echo');

  static Future<String?> echo(String text) =>
      _channel.invokeMethod<String>('echo', text);
}

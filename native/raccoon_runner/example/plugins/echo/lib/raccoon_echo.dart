import 'package:flutter/services.dart';

/// One method, `echo`, answered from a GLib idle callback on Linux, the
/// main queue on macOS, a message posted to the view's window on Windows:
/// a round trip through the main loop the host has to pump.
abstract final class RaccoonEcho {
  static const _channel = MethodChannel('raccoon_echo');

  static Future<String?> echo(String text) =>
      _channel.invokeMethod<String>('echo', text);

  /// A texture of one colour, orange, registered by the plugin; its id for
  /// a [Texture] widget. Fails where the host takes no texture.
  static Future<int?> texture() => _channel.invokeMethod<int>('texture');

  /// A modal dialog that closes itself after [milliseconds], as a user
  /// would; it answers once the dialog is gone. Windows and macOS: while it
  /// is up its own loop holds the platform thread's.
  static Future<bool?> modal(int milliseconds) =>
      _channel.invokeMethod<bool>('modal', milliseconds);

  /// A write on flutter_secure_storage's channel with [options]; the
  /// options that reached the plugin, as sorted key=value pairs. macOS only.
  static Future<String?> secureStorageOptions(Map<String, String> options) =>
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage')
          .invokeMethod<String>('write', {
            'key': 'k',
            'value': 'v',
            'options': options,
          });
}

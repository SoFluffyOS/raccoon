import 'package:flutter/services.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:raccoon_view/src/ide_url_launcher_channels.dart';

/// Serves the hosted app's `flutter/platform` channel with this process's own
/// services: the clipboard is the IDE's clipboard, sounds and haptics are
/// accepted and ignored, and anything else is "no plugin".
final class IdePlatformChannels {
  const IdePlatformChannels({this.codec = const JSONMethodCodec()});

  final MethodCodec codec;

  static const String platformChannel = 'flutter/platform';

  /// Registers this and the plugin channels the IDE serves.
  void register(RunnerClient client) {
    client.registerChannel(platformChannel, handlePlatform);
    IdeUrlLauncherChannels().register(client);
  }

  Future<Uint8List?> handlePlatform(Uint8List data) async {
    final call = codec.decodeMethodCall(ByteData.sublistView(data));
    final result = await _dispatch(call);
    if (result == null) return null;
    final encoded = codec.encodeSuccessEnvelope(result.value);
    return encoded.buffer.asUint8List(
      encoded.offsetInBytes,
      encoded.lengthInBytes,
    );
  }

  Future<_Reply?> _dispatch(MethodCall call) async {
    switch (call.method) {
      case 'Clipboard.setData':
        final text = (call.arguments as Map?)?['text'] as String?;
        await Clipboard.setData(ClipboardData(text: text ?? ''));
        return const _Reply(null);
      case 'Clipboard.getData':
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        return _Reply(data == null ? null : {'text': data.text});
      case 'Clipboard.hasStrings':
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        return _Reply({'value': (data?.text ?? '').isNotEmpty});
      case 'SystemSound.play':
      case 'HapticFeedback.vibrate':
      case 'SystemChrome.setApplicationSwitcherDescription':
      case 'SystemChrome.setEnabledSystemUIMode':
      case 'SystemChrome.setSystemUIOverlayStyle':
      case 'SystemChrome.setPreferredOrientations':
        return const _Reply(null);
      default:
        return null;
    }
  }
}

/// A handled call's result, which may itself be null.
final class _Reply {
  const _Reply(this.value);

  final Object? value;
}

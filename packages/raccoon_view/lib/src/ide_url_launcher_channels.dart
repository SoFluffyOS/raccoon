import 'package:flutter/services.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

/// Opens the hosted app's URLs with this process's launcher. Serves the
/// Pigeon channels of `url_launcher_linux`, so the plugin's Dart side works
/// in the runtime without its native half.
final class IdeUrlLauncherChannels {
  IdeUrlLauncherChannels({
    Future<bool> Function(Uri url)? canLaunch,
    Future<bool> Function(Uri url)? launch,
  }) : _canLaunch = canLaunch ?? launcher.canLaunchUrl,
       _launch =
           launch ??
           ((url) => launcher.launchUrl(
             url,
             mode: launcher.LaunchMode.externalApplication,
           ));

  static const String canLaunchChannel =
      'dev.flutter.pigeon.url_launcher_linux.UrlLauncherApi.canLaunchUrl';
  static const String launchChannel =
      'dev.flutter.pigeon.url_launcher_linux.UrlLauncherApi.launchUrl';

  final Future<bool> Function(Uri url) _canLaunch;
  final Future<bool> Function(Uri url) _launch;
  final MessageCodec<Object?> _codec = const StandardMessageCodec();

  void register(RunnerClient client) {
    client.registerChannel(canLaunchChannel, handleCanLaunch);
    client.registerChannel(launchChannel, handleLaunch);
  }

  Future<Uint8List?> handleCanLaunch(Uint8List data) async {
    final url = _url(data);
    if (url == null) return _reply(['bad-url', 'not a url', null]);
    return _reply([await _canLaunch(url)]);
  }

  /// Pigeon's launchUrl returns null on success, else an error message.
  Future<Uint8List?> handleLaunch(Uint8List data) async {
    final url = _url(data);
    if (url == null) return _reply(['bad-url', 'not a url', null]);
    final launched = await _launch(url);
    return _reply([launched ? null : 'could not launch $url']);
  }

  Uri? _url(Uint8List data) {
    final decoded = _codec.decodeMessage(ByteData.sublistView(data));
    if (decoded case [final String url, ...]) return Uri.tryParse(url);
    return null;
  }

  Uint8List _reply(List<Object?> envelope) {
    final encoded = _codec.encodeMessage(envelope);
    if (encoded == null) return Uint8List(0);
    return encoded.buffer.asUint8List(
      encoded.offsetInBytes,
      encoded.lengthInBytes,
    );
  }
}

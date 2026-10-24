import 'package:flutter/services.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:raccoon_view/src/url_launcher_macos_codec.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

/// Opens the hosted app's URLs with this process's launcher. Serves the
/// Pigeon channels of `url_launcher_linux`, `url_launcher_macos` and
/// `url_launcher_windows`, so the plugin's Dart side works in the runtime
/// without its native half. The APIs differ only in their replies: Linux
/// answers a bool and an error string, macOS a result object, Windows a
/// bool both times.
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

  /// `url_launcher_linux`'s canLaunchUrl channel.
  static const String linuxCanLaunchChannel =
      'dev.flutter.pigeon.url_launcher_linux.UrlLauncherApi.canLaunchUrl';

  /// `url_launcher_linux`'s launchUrl channel.
  static const String linuxLaunchChannel =
      'dev.flutter.pigeon.url_launcher_linux.UrlLauncherApi.launchUrl';

  /// `url_launcher_macos`'s canLaunchUrl channel.
  static const String macosCanLaunchChannel =
      'dev.flutter.pigeon.url_launcher_macos.UrlLauncherApi.canLaunchUrl';

  /// `url_launcher_macos`'s launchUrl channel.
  static const String macosLaunchChannel =
      'dev.flutter.pigeon.url_launcher_macos.UrlLauncherApi.launchUrl';

  /// `url_launcher_windows`'s canLaunchUrl channel.
  static const String windowsCanLaunchChannel =
      'dev.flutter.pigeon.url_launcher_windows.UrlLauncherApi.canLaunchUrl';

  /// `url_launcher_windows`'s launchUrl channel.
  static const String windowsLaunchChannel =
      'dev.flutter.pigeon.url_launcher_windows.UrlLauncherApi.launchUrl';

  static const _invalidUrl = UrlLauncherMacosResult(false, invalidUrl: true);

  final Future<bool> Function(Uri url) _canLaunch;
  final Future<bool> Function(Uri url) _launch;
  final MessageCodec<Object?> _linuxCodec = const StandardMessageCodec();
  final MessageCodec<Object?> _macosCodec = const UrlLauncherMacosCodec();

  /// Serves all three plugins' channels on [client], whichever one the
  /// app's host uses.
  void register(RunnerClient client) {
    client
      ..registerChannel(linuxCanLaunchChannel, handleLinuxCanLaunch)
      ..registerChannel(linuxLaunchChannel, handleLinuxLaunch)
      ..registerChannel(macosCanLaunchChannel, handleMacosCanLaunch)
      ..registerChannel(macosLaunchChannel, handleMacosLaunch)
      ..registerChannel(windowsCanLaunchChannel, handleWindowsCanLaunch)
      ..registerChannel(windowsLaunchChannel, handleWindowsLaunch);
  }

  /// Pigeon's canLaunchUrl returns whether the URL can be opened; one that
  /// does not parse is a `bad-url` error.
  Future<Uint8List?> handleLinuxCanLaunch(Uint8List data) async {
    final url = _url(data);
    if (url == null) return _reply(_linuxCodec, ['bad-url', 'not a url', null]);
    return _reply(_linuxCodec, [await _canLaunch(url)]);
  }

  /// Pigeon's launchUrl returns null on success, else an error message.
  Future<Uint8List?> handleLinuxLaunch(Uint8List data) async {
    final url = _url(data);
    if (url == null) return _reply(_linuxCodec, ['bad-url', 'not a url', null]);
    final launched = await _launch(url);
    return _reply(_linuxCodec, [
      switch (launched) {
        true => null,
        false => 'could not launch $url',
      },
    ]);
  }

  /// Pigeon's canLaunchUrl on macOS returns a result object: whether the
  /// URL can be opened, or that it is invalid.
  Future<Uint8List?> handleMacosCanLaunch(Uint8List data) async {
    final url = _url(data);
    if (url == null) return _reply(_macosCodec, [_invalidUrl]);
    return _reply(_macosCodec, [UrlLauncherMacosResult(await _canLaunch(url))]);
  }

  /// Pigeon's launchUrl on macOS returns a result object: whether it
  /// launched, or that the URL is invalid.
  Future<Uint8List?> handleMacosLaunch(Uint8List data) async {
    final url = _url(data);
    if (url == null) return _reply(_macosCodec, [_invalidUrl]);
    return _reply(_macosCodec, [UrlLauncherMacosResult(await _launch(url))]);
  }

  /// Pigeon's canLaunchUrl on Windows returns whether the URL can be
  /// opened.
  Future<Uint8List?> handleWindowsCanLaunch(Uint8List data) =>
      _windowsReply(data, _canLaunch);

  /// Pigeon's launchUrl on Windows returns whether it launched.
  Future<Uint8List?> handleWindowsLaunch(Uint8List data) =>
      _windowsReply(data, _launch);

  Future<Uint8List?> _windowsReply(
    Uint8List data,
    Future<bool> Function(Uri url) answer,
  ) async {
    final url = _url(data);
    if (url == null) return _reply(_linuxCodec, ['bad-url', 'not a url', null]);
    return _reply(_linuxCodec, [await answer(url)]);
  }

  Uri? _url(Uint8List data) {
    final decoded = _linuxCodec.decodeMessage(ByteData.sublistView(data));
    if (decoded case [final String url, ...]) return Uri.tryParse(url);
    return null;
  }

  Uint8List _reply(MessageCodec<Object?> codec, List<Object?> envelope) {
    final encoded = codec.encodeMessage(envelope);
    if (encoded == null) return Uint8List(0);
    return encoded.buffer.asUint8List(
      encoded.offsetInBytes,
      encoded.lengthInBytes,
    );
  }
}

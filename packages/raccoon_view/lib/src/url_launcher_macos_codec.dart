import 'package:flutter/services.dart';

/// The result `url_launcher_macos` expects from its Pigeon API: a bool with
/// an optional error, which the plugin's codec writes as its own types.
final class UrlLauncherMacosResult {
  const UrlLauncherMacosResult(this.value, {this.invalidUrl = false});

  final bool value;

  /// The plugin's one error: the URL could not be parsed.
  final bool invalidUrl;
}

/// The Pigeon codec of `url_launcher_macos`: the standard codec plus the
/// result (type 130: a list of value and error) and the error enum (type
/// 129: its index).
final class UrlLauncherMacosCodec extends StandardMessageCodec {
  const UrlLauncherMacosCodec();

  static const int _errorType = 129;
  static const int _resultType = 130;
  static const int _invalidUrlIndex = 0;

  @override
  void writeValue(WriteBuffer buffer, Object? value) {
    switch (value) {
      case UrlLauncherMacosResult(:final value, :final invalidUrl):
        buffer.putUint8(_resultType);
        final error = switch (invalidUrl) {
          true => const _InvalidUrl(),
          false => null,
        };
        writeValue(buffer, [value, error]);
      case _InvalidUrl():
        buffer.putUint8(_errorType);
        writeValue(buffer, _invalidUrlIndex);
      default:
        super.writeValue(buffer, value);
    }
  }

  @override
  Object? readValueOfType(int type, ReadBuffer buffer) => switch (type) {
        _errorType => switch (readValue(buffer)) {
            _invalidUrlIndex => const _InvalidUrl(),
            final other =>
              throw FormatException('unknown url_launcher error $other'),
          },
        _resultType => switch (readValue(buffer)) {
            [final bool value, _InvalidUrl()] => UrlLauncherMacosResult(
                value,
                invalidUrl: true,
              ),
            [final bool value, null] => UrlLauncherMacosResult(value),
            _ => throw const FormatException('not a url_launcher result'),
          },
        _ => super.readValueOfType(type, buffer),
      };
}

/// The plugin's error enum has one value; this stands for it.
final class _InvalidUrl {
  const _InvalidUrl();
}

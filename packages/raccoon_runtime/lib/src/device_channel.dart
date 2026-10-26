import 'dart:convert';
import 'dart:typed_data';

import 'package:raccoon_runtime/src/raccoon_entrypoint.dart';
import 'package:raccoon_runtime/src/runner_client.dart';

/// The device a view of the app is shown as (#194): what its safe area
/// covers, in logical pixels, and its platform.
final class DeviceProfile {
  const DeviceProfile({
    this.padding = (top: 0, right: 0, bottom: 0, left: 0),
    this.platform,
  });

  /// The status bar, notch, home indicator: the app's `MediaQuery.padding`.
  final ({double top, double right, double bottom, double left}) padding;

  /// A `TargetPlatform`'s name (`iOS`, `android`) for the app's
  /// `defaultTargetPlatform`; null keeps the host's.
  final String? platform;

  Map<String, Object?> toJson() => {
    'padding': [padding.top, padding.right, padding.bottom, padding.left],
    'platform': platform,
  };

  @override
  bool operator ==(Object other) =>
      other is DeviceProfile &&
      other.padding == padding &&
      other.platform == platform;

  @override
  int get hashCode => Object.hash(padding, platform);
}

/// Answers [RaccoonEntrypoint]'s asks for the device each view is shown as.
/// The entry asks again whenever the view's metrics change, so a profile
/// set while the app runs takes effect at the next size the client sends.
final class DeviceChannel {
  final _profiles = <int, DeviceProfile>{};

  /// What a view with no profile of its own is shown as; null leaves the
  /// app as on the host.
  DeviceProfile? fallback;

  /// Shows the app's [view] (0 is its own) as [profile]; null takes it back
  /// to [fallback].
  void set(int view, DeviceProfile? profile) {
    if (profile == null) {
      _profiles.remove(view);
      return;
    }
    _profiles[view] = profile;
  }

  /// The profile [view] is shown as.
  DeviceProfile? of(int view) => _profiles[view] ?? fallback;

  /// Serves the entry's asks on [client].
  void attach(RunnerClient client) =>
      client.registerChannel(RaccoonEntrypoint.channel, answer);

  /// The reply to one ask: `{"view": id}` in, the profile out as JSON, or
  /// null for none.
  Future<Uint8List?> answer(Uint8List data) async {
    final Object? ask;
    try {
      ask = jsonDecode(utf8.decode(data));
    } on FormatException {
      return null;
    }
    final view = switch (ask) {
      {'view': final int id} => id,
      _ => 0,
    };
    final profile = of(view);
    if (profile == null) return null;
    return Uint8List.fromList(utf8.encode(jsonEncode(profile.toJson())));
  }
}

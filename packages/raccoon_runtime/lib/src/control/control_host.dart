import 'package:raccoon_runtime/src/raccoon_device.dart';
import 'package:raccoon_runtime/src/raccoon_test_device.dart';
import 'package:raccoon_runtime/src/runner_client.dart';
import 'package:raccoon_runtime/src/runner_discovery.dart';
import 'package:raccoon_runtime/src/runner_log.dart';

/// A Raccoon device a host can run apps on: its Flutter device id, its
/// label, and its size when it has one of its own.
final class RaccoonControlDevice {
  const RaccoonControlDevice({
    required this.id,
    required this.label,
    this.size,
  });

  /// A device by its Flutter id, sized as the built-in one of its key is
  /// unless [size] (`390x844@3`) says otherwise.
  factory RaccoonControlDevice.of(String id, {String? label, String? size}) {
    final key = RaccoonControlDevice.keyOf(id);
    final known = key == null ? null : RaccoonDevice.forKey(key);
    final parsed = size == null ? null : RaccoonDevice.parseSize(size);
    final DeviceSize? sized = switch ((parsed, known)) {
      ((:final width, :final height, :final pixelRatio)?, _) => (
        width: width.toDouble(),
        height: height.toDouble(),
        pixelRatio: pixelRatio,
      ),
      (null, RaccoonDevice(:final int width, :final int height)) => (
        width: width.toDouble(),
        height: height.toDouble(),
        pixelRatio: known?.pixelRatio ?? 1,
      ),
      _ => null,
    };
    return RaccoonControlDevice(
      id: id,
      label: label ?? known?.label ?? id,
      size: sized,
    );
  }

  /// The Flutter tool's id: `raccoon-phone`.
  final String id;

  /// What the device picker shows: `Raccoon Phone`.
  final String label;

  /// Its logical size and pixel ratio; null for one sized by the host.
  final DeviceSize? size;

  /// The instance key of a Raccoon device id, as app names carry it:
  /// `phone` for `raccoon-phone`, `1` for `raccoon`; null for any other.
  static String? keyOf(String id) => switch (id) {
    'raccoon' => '1',
    _ when id.startsWith('raccoon-') && id.length > 8 => id.substring(8),
    _ => null,
  };

  /// The device id an app name runs on: `raccoon-phone` for
  /// `hello@phone`, `raccoon` for `hello`.
  static String idOfApp(String appName) => switch (RunnerDiscovery.instanceOf(
    appName,
  )) {
    '1' => 'raccoon',
    final key => 'raccoon-$key',
  };

  /// The app name [project] runs under on device [id]: `hello@phone`.
  static String appNameOn(String project, String id) => switch (keyOf(id)) {
    null => throw ArgumentError.value(id, 'device', 'not a Raccoon device'),
    '1' => project,
    final key => '$project@$key',
  };
}

/// Why a control call failed, with a [code] a client can act on.
final class RaccoonControlError implements Exception {
  const RaccoonControlError(this.code, this.message);

  /// The call's parameters are wrong.
  static const badParams = 'bad_params';

  /// No such method.
  static const unknownMethod = 'unknown_method';

  /// Nothing runs where the call points.
  static const noApp = 'no_app';

  /// More than one app runs where the call points: name one.
  static const ambiguous = 'ambiguous';

  /// The app can't do it, such as a hot reload of a run started elsewhere.
  static const unsupported = 'unsupported';

  /// It was tried and failed.
  static const failed = 'failed';

  /// The caller did not give the endpoint's token.
  static const unauthorized = 'unauthorized';

  final String code;
  final String message;

  Map<String, Object?> toJson() => {'code': code, 'message': message};

  @override
  String toString() => '$code: $message';
}

/// An app a host shows, as the control endpoint drives it. Hosts look
/// their apps up afresh for every call ([RaccoonControlHost.apps]).
abstract interface class RaccoonControlApp {
  /// The runner's app name: `hello@phone`.
  String get name;

  /// The connection the host holds to the app's runner: input goes out on
  /// it, frames come in.
  RunnerClient get client;

  /// The app's logical size and pixel ratio now: what input coordinates
  /// are in.
  DeviceSize get size;

  /// Who started the run: `agent` (through this endpoint), `host` (the
  /// host's own run button), `editor` (a run the host only shows) or
  /// `headless` (no host at all).
  String get startedBy;

  /// The app's Dart VM service, when known.
  String? get vmServiceUri;

  /// Whether [hotReload] and [hotRestart] can work: the host holds the
  /// app's `flutter run`.
  bool get canReload;

  /// Whether a screenshot gives GPU buffer frames back itself: true when
  /// no view of the host shows them.
  bool get releasesGpuFrames;

  Future<void> hotReload();

  Future<void> hotRestart();

  /// Stops the app and its runner.
  Future<void> stop();

  /// Gives the app [size], as the host's board does; the endpoint waits for
  /// the first frame at it.
  Future<void> resize(DeviceSize size);

  /// The run's log so far, oldest first: the app's lines, the runner's and,
  /// for a run the host holds, the Flutter tool's.
  List<DeviceLogLine> logLines();
}

/// What a host gives its control endpoint: its devices, its apps, a way to
/// run more. The simulator serves one; a headless one stands in where no
/// host runs.
abstract interface class RaccoonControlHost {
  /// What the host is: `simulator`, `headless`.
  String get kind;

  /// The Raccoon devices registered with the Flutter tool.
  List<RaccoonControlDevice> devices();

  /// Every app the host shows now.
  List<RaccoonControlApp> apps();

  /// Runs the project at [project] on [device] (`raccoon-phone`), its
  /// entry point [target] or `lib/main.dart`, and returns the app once it
  /// has drawn.
  Future<RaccoonControlApp> run(
    String project, {
    required String device,
    String? target,
  });

  /// Tells whoever watches the host what an agent is doing: [action] on
  /// [app], or on the host when null. The person at the board sees it.
  void announce(RaccoonControlApp? app, String action);
}

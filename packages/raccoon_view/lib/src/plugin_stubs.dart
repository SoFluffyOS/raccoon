import 'package:flutter/services.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';

/// What a stubbed permission check or request answers.
enum StubPermission { granted, denied, permanentlyDenied }

/// Answers the channels of plugins that have no implementation for the
/// runner's host, as a phone would, so the app goes on as it would there
/// (#195): permissions granted (or as [permission] says), a foreground
/// service that starts and stops, ads that initialize and never fill, a
/// vibration that does nothing.
/// Only messages no native plugin took reach the client, so a plugin the
/// runner loaded is never answered here. A method not listed stays "no
/// plugin", as before.
final class PluginStubs {
  PluginStubs({this.permission = StubPermission.granted, this.onAnswered});

  /// What permission checks and requests answer, for every permission.
  StubPermission permission;

  /// The plugins answered here, by package name: what a runner reports
  /// with no implementation for its host and the app can still call.
  static const Set<String> plugins = {
    'permission_handler',
    'google_mobile_ads',
    'flutter_foreground_task',
    'vibration',
  };

  /// Told the first time each plugin is answered here.
  final void Function(String plugin)? onAnswered;

  /// `permission_handler`'s channel (no macOS, Linux or Windows camera,
  /// location, ... implementation).
  static const String permissionHandlerChannel =
      'flutter.baseflow.com/permissions/methods';

  /// `google_mobile_ads`'s channel (Android and iOS only).
  static const String mobileAdsChannel = 'plugins.flutter.io/google_mobile_ads';

  /// `flutter_foreground_task`'s channels (Android and iOS only).
  static const String foregroundTaskChannel = 'flutter_foreground_task/methods';
  static const String foregroundTaskBackgroundChannel =
      'flutter_foreground_task/background';

  /// `vibration`'s channel (Android and iOS only).
  static const String vibrationChannel = 'vibration';

  static const MethodCodec _codec = StandardMethodCodec();

  final _answered = <String>{};
  bool _foregroundRunning = false;

  /// Serves every stubbed plugin's channels on [client].
  void register(RunnerClient client) {
    client
      ..registerChannel(permissionHandlerChannel, handlePermissionHandler)
      ..registerChannel(mobileAdsChannel, handleMobileAds)
      ..registerChannel(foregroundTaskChannel, handleForegroundTask)
      ..registerChannel(foregroundTaskBackgroundChannel, handleForegroundTask)
      ..registerChannel(vibrationChannel, handleVibration);
  }

  /// permission_handler sends a permission's int and reads a
  /// PermissionStatus index back: denied 0, granted 1, permanentlyDenied 4;
  /// a ServiceStatus 1 is enabled.
  Future<Uint8List?> handlePermissionHandler(Uint8List data) async {
    final call = _codec.decodeMethodCall(ByteData.sublistView(data));
    final status = switch (permission) {
      StubPermission.granted => 1,
      StubPermission.denied => 0,
      StubPermission.permanentlyDenied => 4,
    };
    return switch (call.method) {
      'checkPermissionStatus' => _success('permission_handler', status),
      'checkServiceStatus' => _success('permission_handler', 1),
      'requestPermissions' => _success('permission_handler', {
        for (final value in (call.arguments as List? ?? const []))
          value: status,
      }),
      'shouldShowRequestPermissionRationale' => _success(
        'permission_handler',
        false,
      ),
      'openAppSettings' => _success('permission_handler', true),
      _ => null,
    };
  }

  /// google_mobile_ads speaks its own codec; only the method's name is read
  /// here. Initializing answers an InitializationStatus with no adapters
  /// (its type 137, then an empty map); loading an ad succeeds and nothing
  /// ever fills it.
  Future<Uint8List?> handleMobileAds(Uint8List data) async {
    final method = const StandardMessageCodec().readValue(
      ReadBuffer(ByteData.sublistView(data)),
    );
    switch (method) {
      case 'MobileAds#initialize':
        _told('google_mobile_ads');
        final buffer =
            WriteBuffer()
              ..putUint8(0)
              ..putUint8(137);
        const StandardMessageCodec().writeValue(
          buffer,
          const <String, Object>{},
        );
        final done = buffer.done();
        return done.buffer.asUint8List(done.offsetInBytes, done.lengthInBytes);
      case 'MobileAds#getVersionString':
        return _success('google_mobile_ads', '0.0.0');
      case 'isCollapsible':
        return _success('google_mobile_ads', false);
      case 'MobileAds#getRequestConfiguration':
        return null;
      case final String _:
        return _success('google_mobile_ads', null);
      default:
        return null;
    }
  }

  /// flutter_foreground_task's service runs nowhere, but starts and stops:
  /// startService waits for isRunningService to say so. Its notification
  /// permission is a NotificationPermission index: granted 0, denied 1,
  /// permanently_denied 2.
  Future<Uint8List?> handleForegroundTask(Uint8List data) async {
    final call = _codec.decodeMethodCall(ByteData.sublistView(data));
    const plugin = 'flutter_foreground_task';
    switch (call.method) {
      case 'startService':
      case 'restartService':
        _foregroundRunning = true;
        return _success(plugin, null);
      case 'stopService':
        _foregroundRunning = false;
        return _success(plugin, null);
      case 'isRunningService':
        return _success(plugin, _foregroundRunning);
      case 'checkNotificationPermission':
      case 'requestNotificationPermission':
        return _success(plugin, switch (permission) {
          StubPermission.granted => 0,
          StubPermission.denied => 1,
          StubPermission.permanentlyDenied => 2,
        });
      case 'isAppOnForeground':
      case 'attachedActivity':
      case 'isIgnoringBatteryOptimizations':
      case 'openIgnoreBatteryOptimizationSettings':
      case 'requestIgnoreBatteryOptimization':
      case 'canDrawOverlays':
      case 'openSystemAlertWindowSettings':
      case 'canScheduleExactAlarms':
      case 'openAlarmsAndRemindersSettings':
        return _success(plugin, true);
      case 'updateService':
      case 'start':
      case 'sendData':
      case 'minimizeApp':
      case 'launchApp':
      case 'setOnLockScreenVisibility':
      case 'wakeUpScreen':
        return _success(plugin, null);
      default:
        return null;
    }
  }

  /// vibration's Dart side says a desktop has no vibrator without asking;
  /// a vibrate the app doesn't await would throw, so it is answered, and
  /// custom patterns aren't supported, as with no vibrator.
  Future<Uint8List?> handleVibration(Uint8List data) async {
    final call = _codec.decodeMethodCall(ByteData.sublistView(data));
    return switch (call.method) {
      'vibrate' || 'cancel' => _success('vibration', null),
      'hasCustomVibrationsSupport' ||
      'hasAmplitudeControl' => _success('vibration', false),
      _ => null,
    };
  }

  Uint8List _success(String plugin, Object? result) {
    _told(plugin);
    final encoded = _codec.encodeSuccessEnvelope(result);
    return encoded.buffer.asUint8List(
      encoded.offsetInBytes,
      encoded.lengthInBytes,
    );
  }

  void _told(String plugin) {
    if (_answered.add(plugin)) onAnswered?.call(plugin);
  }
}

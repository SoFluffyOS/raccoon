import 'package:flutter/services.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:raccoon_view/src/plugin_stubs.dart';

/// Sends the app sensor readings the way sensors_plus' native side does
/// (#212): a success envelope of `[x, y, z, timestamp µs]` on a sensor's
/// event channel, which an app listening to that sensor receives.
abstract final class SensorEvents {
  static const MethodCodec _codec = StandardMethodCodec();

  /// The accelerometer's channel, gravity included.
  static String get accelerometer => PluginStubs.sensorEventChannels[0];

  /// The user accelerometer's, gravity left out.
  static String get userAccelerometer => PluginStubs.sensorEventChannels[1];

  /// One reading of [x], [y], [z] (m/s²) taken at [at].
  static Uint8List encode(double x, double y, double z, DateTime at) {
    final encoded = _codec.encodeSuccessEnvelope(<double>[
      x,
      y,
      z,
      at.microsecondsSinceEpoch.toDouble(),
    ]);
    return encoded.buffer.asUint8List(
      encoded.offsetInBytes,
      encoded.lengthInBytes,
    );
  }

  /// Shakes the device: half a second of strong side-to-side readings,
  /// about three times gravity each way, on both accelerometers, then rest.
  /// What a shake detector takes for a shake.
  static Future<void> shake(RunnerClient client) async {
    for (var i = 0; i < 8; i++) {
      final x = switch (i.isEven) {
        true => 30.0,
        false => -30.0,
      };
      final now = DateTime.now();
      client
        ..sendToApp(accelerometer, encode(x, 9.81, 0, now))
        ..sendToApp(userAccelerometer, encode(x, 0, 0, now));
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    final now = DateTime.now();
    client
      ..sendToApp(accelerometer, encode(0, 9.81, 0, now))
      ..sendToApp(userAccelerometer, encode(0, 0, 0, now));
  }
}

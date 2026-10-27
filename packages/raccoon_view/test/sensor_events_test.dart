import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raccoon_view/raccoon_view.dart';

void main() {
  test('a reading is what sensors_plus decodes: x, y, z and its time', () {
    final at = DateTime.fromMicrosecondsSinceEpoch(1000);
    final event = const StandardMethodCodec().decodeEnvelope(
      ByteData.sublistView(SensorEvents.encode(30, 9.81, 0, at)),
    );
    expect((event as List).cast<double>(), [30.0, 9.81, 0.0, 1000.0]);
  });

  test('the channels are the accelerometers', () {
    expect(
      SensorEvents.accelerometer,
      'dev.fluttercommunity.plus/sensors/accelerometer',
    );
    expect(
      SensorEvents.userAccelerometer,
      'dev.fluttercommunity.plus/sensors/user_accel',
    );
  });
}

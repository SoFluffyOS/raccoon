import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raccoon_view/raccoon_view.dart';

/// google_mobile_ads' InitializationStatus, as its codec reads it: type
/// 137, then a map of adapter statuses.
class _AdsCodec extends StandardMessageCodec {
  const _AdsCodec();

  @override
  Object? readValueOfType(int type, ReadBuffer buffer) {
    if (type == 137) return ('status', readValue(buffer));
    return super.readValueOfType(type, buffer);
  }
}

void main() {
  const codec = StandardMethodCodec();

  Uint8List call(String method, [Object? arguments]) {
    final data = codec.encodeMethodCall(MethodCall(method, arguments));
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  Object? reply(Uint8List? data, [MethodCodec with_ = codec]) =>
      with_.decodeEnvelope(ByteData.sublistView(data!));

  test('permissions are granted, or as the stubs say', () async {
    final answered = <String>[];
    final stubs = PluginStubs(onAnswered: answered.add);
    expect(
      reply(
        await stubs.handlePermissionHandler(call('checkPermissionStatus', 1)),
      ),
      1,
    );
    expect(
      reply(
        await stubs.handlePermissionHandler(call('requestPermissions', [1, 7])),
      ),
      {1: 1, 7: 1},
    );
    stubs.permission = StubPermission.permanentlyDenied;
    expect(
      reply(
        await stubs.handlePermissionHandler(call('checkPermissionStatus', 1)),
      ),
      4,
    );
    expect(await stubs.handlePermissionHandler(call('somethingNew')), isNull);
    expect(answered, ['permission_handler']);
  });

  test('ads initialize with no adapters and load to nothing', () async {
    final stubs = PluginStubs();
    final status =
        reply(
              await stubs.handleMobileAds(call('MobileAds#initialize')),
              const StandardMethodCodec(_AdsCodec()),
            )!
            as (String, Object?);
    expect(status.$1, 'status');
    expect(status.$2, isEmpty);
    expect(
      reply(await stubs.handleMobileAds(call('loadBannerAd', {'adId': 1}))),
      isNull,
    );
    expect(reply(await stubs.handleMobileAds(call('isCollapsible'))), isFalse);
  });

  test('a foreground service starts and stops', () async {
    final stubs = PluginStubs();
    Future<Object?> task(String method) async =>
        reply(await stubs.handleForegroundTask(call(method)));
    expect(await task('isRunningService'), isFalse);
    await task('startService');
    expect(await task('isRunningService'), isTrue);
    await task('stopService');
    expect(await task('isRunningService'), isFalse);
    expect(await task('checkNotificationPermission'), 0);
  });

  test('a vibration does nothing, and there are no custom ones', () async {
    final stubs = PluginStubs();
    expect(
      reply(await stubs.handleVibration(call('vibrate', {'duration': 500}))),
      isNull,
    );
    expect(
      reply(await stubs.handleVibration(call('hasCustomVibrationsSupport'))),
      isFalse,
    );
    expect(await stubs.handleVibration(call('somethingNew')), isNull);
  });

  test('sensors are listened to and stay quiet', () async {
    final stubs = PluginStubs();
    expect(
      reply(
        await stubs.handleSensors(
          call('setAccelerationSamplingPeriod', 200000),
        ),
      ),
      isNull,
    );
    expect(reply(await stubs.handleSensors(call('listen'))), isNull);
    expect(await stubs.handleSensors(call('somethingNew')), isNull);
  });

  test('tracking is authorized, or denied with no identifier', () async {
    final stubs = PluginStubs();
    expect(
      reply(
        await stubs.handleAppTracking(call('requestTrackingAuthorization')),
      ),
      3,
    );
    stubs.permission = StubPermission.denied;
    expect(
      reply(
        await stubs.handleAppTracking(call('getTrackingAuthorizationStatus')),
      ),
      2,
    );
    expect(
      reply(await stubs.handleAppTracking(call('getAdvertisingIdentifier'))),
      '00000000-0000-0000-0000-000000000000',
    );
  });
}

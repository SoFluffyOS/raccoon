import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Calls the channels the runner answers itself before the first frame, the
/// way the plugins do: desktop_window, window_manager, window_size and
/// screen_retriever (0.2's channel and 0.1's), and
/// shared_preferences_foundation's two Pigeon APIs (Wonderous awaits
/// setMinWindowSize and loads its settings in its bootstrap). Shows a green
/// box when every call was answered as expected and a red one otherwise. The
/// result does not depend on a client. Expects the runner's default 800x600
/// view at a pixel ratio of 1 and an empty data directory, if any. Prints
/// XDG_DATA_HOME: and what the app sees, for the data directory test,
/// RACCOON_ENDPOINT: for package:raccoon, then LOCALES:, BRIGHTNESS: and
/// LIFECYCLE:, as the runner told the engine, DEVICE: whenever the
/// metrics or settings change, and LIFECYCLE: and ROUTE: for what a client
/// sends it.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Where the Dart-only Linux plugins would put the app's files: the runner
  // points this into the app's data directory when it has one.
  print('XDG_DATA_HOME:${Platform.environment['XDG_DATA_HOME'] ?? ''}');
  print('RACCOON_ENDPOINT:${Platform.environment['RACCOON_ENDPOINT'] ?? ''}');
  final failures = <String>[];
  Future<void> check(String name, Future<bool> Function() call) async {
    try {
      if (!await call()) failures.add(name);
    } catch (error) {
      failures.add('$name: $error');
    }
  }

  const desktopWindow = MethodChannel('desktop_window');
  await check('desktop_window.setMinWindowSize', () async {
    await desktopWindow.invokeMethod('setMinWindowSize', {
      'width': 400.0,
      'height': 300.0,
    });
    return true;
  });
  await check('desktop_window.getWindowSize', () async {
    final size = await desktopWindow.invokeMethod('getWindowSize');
    return size is List && size[0] == 800.0 && size[1] == 600.0;
  });
  await check('desktop_window.setFullScreen', () async {
    await desktopWindow.invokeMethod('setFullScreen', {'fullscreen': true});
    return await desktopWindow.invokeMethod('getFullScreen') == true;
  });
  await check('desktop_window.focus', () async {
    await desktopWindow.invokeMethod('focus');
    return true;
  });

  const windowManager = MethodChannel('window_manager');
  await check('window_manager.getBounds', () async {
    await windowManager.invokeMethod('ensureInitialized');
    final Map<dynamic, dynamic> bounds = await windowManager.invokeMethod(
      'getBounds',
      {'devicePixelRatio': 1.0},
    );
    final rect = Rect.fromLTWH(
      bounds['x'],
      bounds['y'],
      bounds['width'],
      bounds['height'],
    );
    return rect == const Rect.fromLTWH(0, 0, 800, 600);
  });
  await check('window_manager.getTitle', () async {
    await windowManager.invokeMethod('setTitle', {'title': 'Raccoon'});
    final String title = await windowManager.invokeMethod('getTitle');
    final bool focused = await windowManager.invokeMethod('isFocused');
    final id = await windowManager.invokeMethod('getId') as int;
    return title == 'Raccoon' && focused && id == 0;
  });

  const windowSize = MethodChannel('flutter/windowsize');
  await check('window_size.getWindowInfo', () async {
    final info = await windowSize.invokeMethod('getWindowInfo');
    final frame = (info['frame'] as List).cast<double>();
    final double scale = info['scaleFactor'];
    final screen = info['screen'] as Map;
    return frame[2] == 800.0 &&
        frame[3] == 600.0 &&
        scale == 1.0 &&
        (screen['visibleFrame'] as List).cast<double>()[2] == 800.0;
  });
  await check('window_size.getWindowMinimumSize', () async {
    await windowSize.invokeMethod('setWindowMinimumSize', [640.0, 480.0]);
    final size = await windowSize.invokeMethod('getWindowMinimumSize');
    return (size as List).cast<double>()[0] == 640.0;
  });

  // screen_retriever: the pane is the one display. Sizes come as doubles,
  // which the plugin hands to Size and Offset as they are.
  for (final name in [
    'dev.leanflutter.plugins/screen_retriever',
    'screen_retriever',
  ]) {
    final screens = MethodChannel(name);
    const ratio = {'devicePixelRatio': 1.0};
    await check('$name.getPrimaryDisplay', () async {
      final Map<dynamic, dynamic> display = await screens.invokeMethod(
        'getPrimaryDisplay',
        ratio,
      );
      final size = display['size'] as Map;
      return display['id'] is String &&
          size['width'] == 800.0 &&
          size['height'] == 600.0 &&
          (display['visibleSize'] as Map)['width'] is double &&
          (display['visiblePosition'] as Map)['dx'] == 0.0 &&
          display['scaleFactor'] == 1.0;
    });
    await check('$name.getAllDisplays', () async {
      final Map<dynamic, dynamic> all = await screens.invokeMethod(
        'getAllDisplays',
        ratio,
      );
      return (all['displays'] as List).length == 1;
    });
    await check('$name.getCursorScreenPoint', () async {
      final Map<dynamic, dynamic> point = await screens.invokeMethod(
        'getCursorScreenPoint',
        ratio,
      );
      return point['dx'] is double && point['dy'] is double;
    });
  }
  await check('screen_retriever events', () async {
    const events = MethodChannel(
      'dev.leanflutter.plugins/screen_retriever_event',
    );
    await events.invokeMethod('listen');
    await events.invokeMethod('cancel');
    return true;
  });

  // shared_preferences_foundation: one BasicMessageChannel per method, the
  // arguments as a list, the reply as [result] or [code, message, details].
  Future<Object?> pigeon(String api, String method, List<Object?> args) async {
    final channel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.shared_preferences_foundation.$api.$method',
      const _PigeonCodec(),
    );
    final reply = await channel.send(args) as List<Object?>?;
    if (reply == null || reply.length != 1) throw 'reply $reply';
    return reply.single;
  }

  const legacy = 'LegacyUserDefaultsApi';
  await check('shared_preferences legacy', () async {
    await pigeon(legacy, 'setValue', ['flutter.name', 'raccoon']);
    await pigeon(legacy, 'setBool', ['flutter.on', true]);
    await pigeon(legacy, 'setDouble', ['flutter.ratio', 1.5]);
    await pigeon(legacy, 'setValue', [
      'flutter.list',
      ['a', 'b'],
    ]);
    await pigeon(legacy, 'setValue', ['other.count', 3]);
    final all = await pigeon(legacy, 'getAll', ['flutter.', null]) as Map;
    final allowed = await pigeon(legacy, 'getAll', [
      'flutter.',
      ['flutter.on'],
    ]);
    await pigeon(legacy, 'remove', ['flutter.on']);
    final cleared = await pigeon(legacy, 'clear', ['flutter.', null]);
    final left = await pigeon(legacy, 'getAll', ['', null]) as Map;
    return all.length == 4 &&
        all['flutter.name'] == 'raccoon' &&
        all['flutter.ratio'] == 1.5 &&
        (all['flutter.list'] as List).join() == 'ab' &&
        (allowed as Map).keys.single == 'flutter.on' &&
        cleared == true &&
        left.length == 1 &&
        left['other.count'] == 3;
  });
  const asyncApi = 'UserDefaultsApi';
  await check('shared_preferences async', () async {
    const suite = _Options('raccoon.suite');
    await pigeon(asyncApi, 'set', ['count', 7, suite]);
    final value = await pigeon(asyncApi, 'getValue', ['count', suite]);
    final standard = await pigeon(asyncApi, 'getValue', [
      'count',
      const _Options(null),
    ]);
    final keys = await pigeon(asyncApi, 'getKeys', [null, suite]) as List;
    await pigeon(asyncApi, 'clear', [null, suite]);
    final all = await pigeon(asyncApi, 'getAll', [null, suite]) as Map;
    return value == 7 &&
        standard == null &&
        keys.single == 'count' &&
        all.isEmpty;
  });

  if (failures.isNotEmpty) debugPrint('runner channels failed: $failures');
  // The host's locales and appearance, as the runner told the engine; read
  // after the calls above, as an app's first build would.
  final dispatcher = PlatformDispatcher.instance;
  print('LOCALES:${dispatcher.locales.join(',')}');
  print('BRIGHTNESS:${dispatcher.platformBrightness.name}');
  print('LIFECYCLE:${WidgetsBinding.instance.lifecycleState?.name}');
  // And what a client sets in their place: now and each time it does
  // (#193).
  void device() {
    final view = dispatcher.implicitView;
    print(
      'DEVICE:${dispatcher.locales.join(',')};'
      '${dispatcher.platformBrightness.name};'
      '${dispatcher.textScaleFactor};'
      '${dispatcher.alwaysUse24HourFormat};'
      '${view?.viewInsets.bottom}',
    );
  }

  device();
  WidgetsBinding.instance.addObserver(_Device(device));
  runApp(ChannelsApp(ok: failures.isEmpty));
}

class _Device with WidgetsBindingObserver {
  _Device(this.changed);

  final VoidCallback changed;

  @override
  void didChangeMetrics() => changed();

  @override
  void didChangeLocales(List<Locale>? locales) => changed();

  @override
  void didChangePlatformBrightness() => changed();

  @override
  void didChangeTextScaleFactor() => changed();

  // What a client sends the app as a device's controls do (#199).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      print('LIFECYCLE:${state.name}');

  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) {
    print('ROUTE:${routeInformation.uri}');
    return Future.value(true);
  }
}

/// SharedPreferencesPigeonOptions as Pigeon sends it: type 129, then its
/// fields as a list.
class _Options {
  const _Options(this.suiteName);

  final String? suiteName;
}

class _PigeonCodec extends StandardMessageCodec {
  const _PigeonCodec();

  @override
  void writeValue(WriteBuffer buffer, Object? value) {
    if (value is _Options) {
      buffer.putUint8(129);
      writeValue(buffer, [value.suiteName]);
    } else {
      super.writeValue(buffer, value);
    }
  }
}

class ChannelsApp extends StatelessWidget {
  const ChannelsApp({super.key, required this.ok});

  final bool ok;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF1E88E5),
      child: Center(
        child: SizedBox(
          width: 240,
          height: 120,
          child: ColoredBox(
            color: ok ? const Color(0xFF43A047) : const Color(0xFFE53935),
          ),
        ),
      ),
    );
  }
}

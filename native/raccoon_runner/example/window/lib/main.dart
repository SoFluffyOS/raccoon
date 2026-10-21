import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Calls the window plugins' channels before the first frame, the way
/// desktop_window, window_manager and window_size do (Wonderous awaits
/// desktop_window's setMinWindowSize in its bootstrap), then shows a green box
/// when every call was answered as expected and a red one otherwise. The
/// runner answers these channels itself, so the result does not depend on a
/// client. Expects the runner's default 800x600 view at a pixel ratio of 1.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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

  if (failures.isNotEmpty) debugPrint('window channels failed: $failures');
  runApp(WindowApp(ok: failures.isEmpty));
}

class WindowApp extends StatelessWidget {
  const WindowApp({super.key, required this.ok});

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

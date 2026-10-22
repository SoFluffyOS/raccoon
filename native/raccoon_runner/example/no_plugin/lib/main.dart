import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The channel of a plugin nobody serves, named the way Pigeon names one:
/// the plugin's package, its host API, the method.
const channelName = 'dev.flutter.pigeon.absent_plugin.AbsentHostApi.initialize';

/// Calls a plugin nobody serves in main(), before runApp, the way
/// `await Firebase.initializeApp()` does on a host the plugin does not
/// support. A Pigeon channel's generated code turns the null reply into a
/// PlatformException, as here. Prints NO_PLUGIN: with what came back and how
/// long it took, then lets the exception escape: main() dies and no frame is
/// ever drawn.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final watch = Stopwatch()..start();
  const channel = BasicMessageChannel<Object?>(
    channelName,
    StandardMessageCodec(),
  );
  final reply = await channel.send(null);
  // ignore: avoid_print
  print('NO_PLUGIN:$reply after ${watch.elapsedMilliseconds} ms');
  if (reply == null) {
    throw PlatformException(
      code: 'channel-error',
      message: 'Unable to establish connection on channel: "$channelName".',
    );
  }
  runApp(const ColoredBox(color: Color(0xFF1E88E5)));
}

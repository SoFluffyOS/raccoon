import 'package:flutter/widgets.dart';
import 'package:raccoon_static_core/raccoon_static_core.dart';
import 'package:raccoon_static_user/raccoon_static_user.dart';

/// Sets 42 through raccoon_static_core, then reads it back through
/// raccoon_static_user, which links the former as firebase_auth links
/// firebase_core. Prints STATIC:<what it read>: 42 when both share one
/// module, 0 when each has its own copy; STATIC:error and why otherwise.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ColoredBox(color: Color(0xFF2E7D32)));
  try {
    await RaccoonStaticCore.set(42);
    final seen = await RaccoonStaticUser.get();
    // ignore: avoid_print
    print('STATIC:$seen');
  } catch (error) {
    // ignore: avoid_print
    print('STATIC:error $error');
  }
}

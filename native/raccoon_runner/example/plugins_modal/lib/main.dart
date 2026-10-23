import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:raccoon_echo/raccoon_echo.dart';

/// A colour that changes every frame, so frames keep coming as long as the
/// host serves vsync; once the first is drawn, a modal dialog from the
/// echo plugin that closes itself after two seconds, between MODAL:start
/// and MODAL:done.
void main() {
  runApp(const _Cycling());
  SchedulerBinding.instance.addPostFrameCallback((_) async {
    // ignore: avoid_print
    print('MODAL:start');
    try {
      await RaccoonEcho.modal(2000);
      // ignore: avoid_print
      print('MODAL:done');
    } catch (error) {
      // ignore: avoid_print
      print('MODAL:error $error');
    }
  });
}

class _Cycling extends StatefulWidget {
  const _Cycling();

  @override
  State<_Cycling> createState() => _CyclingState();
}

class _CyclingState extends State<_Cycling>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  int _frame = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => setState(() => _frame++))..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: Color(0xFF000000 | (_frame * 2654435761 & 0xFFFFFF)));
}

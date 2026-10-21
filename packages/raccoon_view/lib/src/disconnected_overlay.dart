import 'package:flutter/widgets.dart';

/// Over the last frame once the runner is gone: what shows is no longer live.
class DisconnectedOverlay extends StatelessWidget {
  const DisconnectedOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0x99000000),
      child: Center(
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Text(
            'Runner disconnected',
            style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 14),
          ),
        ),
      ),
    );
  }
}

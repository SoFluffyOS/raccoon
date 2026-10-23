import 'package:flutter/widgets.dart';
import 'package:native_add/native_add.dart';

/// Calls native_add's code asset before the first frame and prints what came
/// back: NATIVE:42, or NATIVE:error when the asset never loaded. Green when
/// it answered, red otherwise.
void main() {
  String line;
  try {
    line = 'NATIVE:${add(40, 2)}';
  } catch (error) {
    line = 'NATIVE:error $error';
  }
  // ignore: avoid_print
  print(line);
  runApp(
    ColoredBox(
      color: line == 'NATIVE:42'
          ? const Color(0xFF2E7D32)
          : const Color(0xFFC62828),
    ),
  );
}

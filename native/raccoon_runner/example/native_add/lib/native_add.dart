import 'dart:ffi';

/// [a] + [b], in C: the code asset hook/build.dart builds.
@Native<Int32 Function(Int32, Int32)>()
external int add(int a, int b);

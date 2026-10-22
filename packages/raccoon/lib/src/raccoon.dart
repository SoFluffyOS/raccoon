import 'dart:io';

import 'package:raccoon/src/protocol.dart';

/// Whether this process runs inside the Raccoon runtime, and where the runner
/// is.
final class Raccoon {
  const Raccoon._(this._environment);

  /// Reads the real process environment.
  factory Raccoon() => Raccoon._(Platform.environment);

  /// Reads [environment] instead of the process environment, for tests.
  const factory Raccoon.withEnvironment(Map<String, String> environment) =
      Raccoon._;

  final Map<String, String> _environment;

  /// The runner's endpoint, or null outside the runtime.
  String? get endpoint {
    final value = _environment[RaccoonProtocol.endpointVariable];
    if (value == null || value.isEmpty) return null;
    return value;
  }

  /// True when the runner started this process.
  bool get isPresent => endpoint != null;
}

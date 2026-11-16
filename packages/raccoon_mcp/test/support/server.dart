import 'dart:io';

import 'package:path/path.dart' as p;

String? _snapshot;

/// The server compiled to a kernel snapshot once per test run, so a client
/// spawning it finds it answering at once: from source, `dart run` takes
/// seconds to compile first on a CI machine, longer than an MCP client
/// waits for its first request before it falls back to an older handshake
/// the server then refuses.
Future<List<String>> serverCommand() async {
  final existing = _snapshot;
  if (existing != null) return [existing];
  final folder = Directory.systemTemp.createTempSync('raccoon_mcp_server');
  final dill = p.join(folder.path, 'raccoon_mcp.dill');
  final compiled = await Process.run(Platform.resolvedExecutable, [
    'compile',
    'kernel',
    'bin/raccoon_mcp.dart',
    '-o',
    dill,
  ]);
  if (compiled.exitCode != 0) {
    throw StateError('dart compile kernel failed:\n${compiled.stderr}');
  }
  return [_snapshot = dill];
}

import 'dart:async';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:raccoon_mcp/raccoon_mcp.dart';

const _usage = '''
raccoon_mcp: an MCP server over stdio for Raccoon devices.

  raccoon_mcp [--host auto|simulator|headless] [--flutter <path>] [--verbose]

--host       auto (default): the open Raccoon Simulator's board when there is
             one, runs of this process with no window otherwise.
             simulator: only the simulator. headless: never the simulator.
--flutter    The Flutter tool headless runs use (flutter on the PATH).
--verbose    Headless: say each action on stderr.

Register it with an MCP client, for example:
  claude mcp add raccoon -- raccoon_mcp
''';

Future<void> main(List<String> arguments) async {
  var choice = HostChoice.auto;
  var flutter = 'flutter';
  var verbose = false;
  for (var i = 0; i < arguments.length; i++) {
    switch (arguments[i]) {
      case '--host' when i + 1 < arguments.length:
        final name = arguments[++i];
        choice = HostChoice.values.firstWhere(
          (value) => value.name == name,
          orElse: () => _fail('--host is auto, simulator or headless'),
        );
      case '--flutter' when i + 1 < arguments.length:
        flutter = arguments[++i];
      case '--verbose':
        verbose = true;
      case '-h' || '--help':
        stdout.write(_usage);
        return;
      default:
        _fail('unknown argument ${arguments[i]}');
    }
  }

  final bridge = RaccoonBridge(choice: choice, flutter: flutter);
  bridge.headless.verbose = verbose;
  final server = McpServer(
    const Implementation(name: 'raccoon_mcp', version: '0.1.0'),
    options: const McpServerOptions(
      capabilities: ServerCapabilities(tools: ServerCapabilitiesTools()),
      instructions:
          'Drives Flutter apps on Raccoon devices. run a project on '
          'raccoon-phone or raccoon-tablet, take a screenshot (logical: true '
          'gives an image in the logical pixels tap and the rest take), act, '
          'look again. With a Raccoon Simulator open, a person watches every '
          'step on its board.',
    ),
  );
  registerRaccoonTools(server, bridge);

  final done = Completer<void>();
  Future<void> finish() async {
    if (done.isCompleted) return;
    await bridge.close();
    if (!done.isCompleted) done.complete();
  }

  server.server.onclose = () => unawaited(finish());
  final signals =
      [
        ProcessSignal.sigint.watch(),
        if (!Platform.isWindows) ProcessSignal.sigterm.watch(),
      ].map((signal) => signal.listen((_) => unawaited(finish()))).toList();
  await server.connect(StdioServerTransport());
  await done.future;
  for (final signal in signals) {
    await signal.cancel();
  }
  exit(0);
}

Never _fail(String message) {
  stderr
    ..writeln('raccoon_mcp: $message')
    ..write(_usage);
  exit(64);
}

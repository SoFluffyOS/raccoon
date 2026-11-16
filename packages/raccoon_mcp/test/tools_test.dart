import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:raccoon_mcp/raccoon_mcp.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

import 'support/server.dart';

/// A host with devices and no apps, whose run says what it was asked.
final class _Host implements RaccoonControlHost {
  @override
  String get kind => 'fake';

  @override
  List<RaccoonControlDevice> devices() => [
    RaccoonControlDevice.of('raccoon-phone'),
  ];

  @override
  List<RaccoonControlApp> apps() => const [];

  @override
  Future<RaccoonControlApp> run(
    String project, {
    required String device,
    String? target,
  }) async =>
      throw RaccoonControlError(
        RaccoonControlError.failed,
        'asked to run $project on $device',
      );

  @override
  void announce(RaccoonControlApp? app, String action) {}
}

/// A Flutter config folder (`XDG_CONFIG_HOME` holds the tool's files
/// itself) whose custom devices are phone and tablet.
Directory _config(Directory temp) {
  final config = Directory(p.join(temp.path, 'config'));
  File(p.join(config.path, 'custom_devices.json'))
    ..createSync(recursive: true)
    ..writeAsStringSync(
      jsonEncode({
        'custom-devices': [
          for (final (id, size) in [
            ('raccoon-phone', '390x844@3'),
            ('raccoon-tablet', '820x1180@2'),
          ])
            {
              'id': id,
              'label': 'L $id',
              'runDebug': ['raccoon-device', 'run', '--size', size],
            },
          {'id': 'pocket', 'label': 'Not ours'},
        ],
      }),
    );
  return config;
}

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('raccoon_mcp'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('the tools are #48\'s, each with a schema that reads', () {
    expect(
      [for (final tool in raccoonTools) tool.name],
      [
        'list_devices',
        'run',
        'stop',
        'hot_reload',
        'hot_restart',
        'screenshot',
        'tap',
        'long_press',
        'drag',
        'scroll',
        'type_text',
        'press_key',
        'logs',
        'resize',
      ],
    );
    expect([
      for (final tool in raccoonTools) tool.name,
    ], RaccoonControl.methods);
    for (final tool in raccoonTools) {
      expect(JsonSchema.fromJson(tool.inputSchema), isA<JsonObject>());
      for (final name in tool.required) {
        expect(tool.properties, contains(name), reason: tool.name);
      }
    }
  });

  group('with a simulator', () {
    late RaccoonControlServer server;
    late RaccoonBridge bridge;

    setUp(() async {
      final folder = p.join(temp.path, 'control');
      server = await RaccoonControlServer.start(
        RaccoonControl(_Host()),
        kind: 'fake',
        directory: folder,
      );
      bridge = RaccoonBridge(
        workingDirectory: '/work',
        environment: const {'HOME': '/home/me'},
        discover: () => RaccoonControlClient.discover(directory: folder),
      );
    });

    tearDown(() async {
      await bridge.close();
      await server.close();
    });

    test('calls go to it, and say so', () async {
      final result = await bridge.call('list_devices', {});
      expect(result['host'], 'fake');
      expect(result['devices'], hasLength(1));
    });

    test('a project path is made absolute where the server runs', () async {
      Future<String> asked(String project) async {
        try {
          await bridge.call('run', {'project': project});
        } on RaccoonControlError catch (error) {
          return error.message;
        }
        return 'ran';
      }

      expect(await asked('app'), 'asked to run /work/app on raccoon-phone');
      expect(
        await asked('~/app'),
        'asked to run /home/me/app on raccoon-phone',
      );
      expect(await asked('/abs/app'), 'asked to run /abs/app on raccoon-phone');
    });

    test('a failure is a tool error the agent reads', () async {
      final result = await callTool(bridge, 'tap', {'x': 1, 'y': 1});
      expect(result.isError, isTrue);
      expect(
        (result.content.single as TextContent).text,
        startsWith('no_app: nothing runs'),
      );
    });
  });

  test(
    'with none open, the devices are the Flutter tool\'s, headless',
    () async {
      final config = _config(temp);
      final bridge = RaccoonBridge(
        discover: () async => null,
        headless: HeadlessHost(environment: {'XDG_CONFIG_HOME': config.path}),
      );
      try {
        final result = await bridge.call('list_devices', {});
        expect(result['host'], 'headless');
        final devices = result['devices'] as List;
        expect(
          [for (final d in devices) (d as Map)['id']],
          ['raccoon-phone', 'raccoon-tablet'],
        );
        expect((devices.last as Map)['size'], {
          'width': 820,
          'height': 1180,
          'pixel_ratio': 2,
        });
      } finally {
        await bridge.close();
      }
    },
  );

  test('the server speaks MCP over stdio', () async {
    final config = _config(temp);
    final client = McpClient(
      const Implementation(name: 'raccoon_mcp_test', version: '1.0.0'),
    );
    await client.connect(
      StdioClientTransport(
        StdioServerParameters(
          command: Platform.resolvedExecutable,
          args: [...await serverCommand(), '--host', 'headless'],
          environment: {'XDG_CONFIG_HOME': config.path},
        ),
      ),
    );
    try {
      final tools = await client.listTools();
      expect([
        for (final tool in tools.tools) tool.name,
      ], unorderedEquals(RaccoonControl.methods));
      final listed = await client.callTool(
        const CallToolRequest(name: 'list_devices', arguments: {}),
      );
      expect(listed.isError, isFalse);
      expect(listed.structuredContent?['host'], 'headless');
      final tapped = await client.callTool(
        const CallToolRequest(name: 'tap', arguments: {'x': 1, 'y': 2}),
      );
      expect(tapped.isError, isTrue);
    } finally {
      await client.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

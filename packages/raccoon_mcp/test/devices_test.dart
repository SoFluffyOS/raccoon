// example/hello on Raccoon devices through raccoon_mcp's tools, over stdio
// as an agent's client calls them. Two ways:
//
//   with a Raccoon Simulator open: --host simulator, on its board;
//   RACCOON_MCP_HEADLESS=1 dart test: --host headless, no window at all.
//
// Each needs the devices registered (raccoon_device setup, then add phone
// and tablet) and a runner; without them, or without a simulator, they skip.

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

import 'support/server.dart';

const red = (0xE5, 0x39, 0x35);
const green = (0x43, 0xA0, 0x47);

final hello = p.normalize(
  p.join(
    Directory.current.path,
    '..',
    '..',
    'native',
    'raccoon_runner',
    'example',
    'hello',
  ),
);

/// raccoon_mcp over stdio, with [host].
Future<McpClient> connect(String host) async {
  final client = McpClient(
    const Implementation(name: 'raccoon_mcp_devices_test', version: '1.0.0'),
  );
  await client.connect(
    StdioClientTransport(
      StdioServerParameters(
        command: Platform.resolvedExecutable,
        args: [...await serverCommand(), '--host', host],
      ),
    ),
  );
  return client;
}

/// Calls [name] and returns its structured result; fails on a tool error.
Future<Map<String, dynamic>> call(
  McpClient client,
  String name, [
  Map<String, Object?> arguments = const {},
]) async {
  final clock = Stopwatch()..start();
  final result = await client.callTool(
    CallToolRequest(name: name, arguments: arguments),
  );
  final text =
      [
        for (final content in result.content)
          if (content is TextContent) content.text,
      ].join();
  expect(result.isError, isFalse, reason: '$name: $text');
  print('  $name ${jsonEncode(arguments)}: ${clock.elapsedMilliseconds} ms');
  final structured = Map<String, dynamic>.of(result.structuredContent ?? {});
  for (final content in result.content) {
    if (content is ImageContent) structured['image'] = content.data;
  }
  return structured;
}

/// The colour at logical ([x], [y]) of a screenshot taken with logical:
/// true.
(int, int, int) colorAt(Map<String, dynamic> shot, double x, double y) {
  final image = img.decodePng(base64Decode(shot['image'] as String))!;
  final pixel = image.getPixel(x.floor(), y.floor());
  return (pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt());
}

/// The session #48 asks for: hello on a phone and a tablet, a screenshot
/// of each, taps through its flow, a resize, the logs with the runner's own
/// lines, a hot reload and restart, stop.
Future<void> session(McpClient client, String host) async {
  final devices = await call(client, 'list_devices');
  expect(devices['host'], host);
  final ids = [for (final d in devices['devices'] as List) (d as Map)['id']];
  expect(ids, containsAll(['raccoon-phone', 'raccoon-tablet']));

  final phone = await call(client, 'run', {
    'project': hello,
    'device': 'raccoon-phone',
  });
  final tablet = await call(client, 'run', {
    'project': hello,
    'device': 'raccoon-tablet',
  });
  try {
    expect((phone['app'] as Map)['name'], 'hello@phone');
    expect((tablet['app'] as Map)['name'], 'hello@tablet');
    // The phone at its own size, whatever a board left it at before.
    await call(client, 'resize', {
      'device': 'raccoon-phone',
      'width': 390,
      'height': 844,
      'pixel_ratio': 3,
    });

    final full = await call(client, 'screenshot', {'device': 'raccoon-phone'});
    expect((full['width'], full['height']), (1170, 2532));
    final shotTablet = await call(client, 'screenshot', {
      'device': 'raccoon-tablet',
      'logical': true,
    });
    final tabletSize = (tablet['app'] as Map)['size'] as Map;
    final (tw, th) = (
      (tabletSize['width'] as num).toDouble(),
      (tabletSize['height'] as num).toDouble(),
    );
    expect(colorAt(shotTablet, tw / 2, th / 2), red);

    // The box toggles red, green, red with each tap.
    await call(client, 'tap', {'device': 'raccoon-phone', 'x': 195, 'y': 422});
    var shot = await call(client, 'screenshot', {
      'device': 'raccoon-phone',
      'logical': true,
    });
    expect((shot['width'], shot['height']), (390, 844));
    expect(colorAt(shot, 195, 422), green);
    await call(client, 'tap', {
      'device': 'raccoon-tablet',
      'x': tw / 2,
      'y': th / 2,
    });
    expect(
      colorAt(
        await call(client, 'screenshot', {'device': 'tablet', 'logical': true}),
        tw / 2,
        th / 2,
      ),
      green,
    );

    final resized = await call(client, 'resize', {
      'device': 'raccoon-phone',
      'width': 360,
      'height': 640,
      'pixel_ratio': 2,
    });
    expect(((resized['app'] as Map)['size'] as Map)['width'], 360);
    shot = await call(client, 'screenshot', {'device': 'raccoon-phone'});
    expect((shot['width'], shot['height']), (720, 1280));
    expect(colorAt(shot, 360, 640), green, reason: 'state kept');

    final runner = await call(client, 'logs', {
      'device': 'raccoon-phone',
      'source': 'runner',
      'last': 0,
    });
    final lines = [
      for (final line in runner['lines'] as List)
        (line as Map)['text'] as String,
    ];
    print('  runner lines: ${lines.length}, e.g. ${lines.take(3).toList()}');
    expect(lines, contains(contains('first frame')));

    await call(client, 'hot_reload', {'device': 'raccoon-phone'});
    expect(
      colorAt(
        await call(client, 'screenshot', {'device': 'phone', 'logical': true}),
        180,
        320,
      ),
      green,
      reason: 'a hot reload keeps the state',
    );
    await call(client, 'hot_restart', {'device': 'raccoon-phone'});
    expect(
      colorAt(
        await call(client, 'screenshot', {'device': 'phone', 'logical': true}),
        180,
        320,
      ),
      red,
      reason: 'a hot restart starts it over',
    );
    final tool = await call(client, 'logs', {
      'device': 'raccoon-phone',
      'source': 'tool',
      'pattern': 'Hot restart|Restarted',
    });
    print('  tool lines on the restart: ${tool['lines']}');
  } finally {
    // As the phone was before, for the next run's board.
    await client.callTool(
      const CallToolRequest(
        name: 'resize',
        arguments: {
          'device': 'raccoon-phone',
          'width': 390,
          'height': 844,
          'pixel_ratio': 3,
        },
      ),
    );
    for (final device in ['raccoon-phone', 'raccoon-tablet']) {
      await client.callTool(
        CallToolRequest(name: 'stop', arguments: {'device': device}),
      );
    }
  }
  final after = await call(client, 'list_devices');
  for (final device in after['devices'] as List) {
    final apps = (device as Map)['apps'] as List;
    expect(
      apps.where((app) => (app as Map)['project'] == 'hello'),
      isEmpty,
      reason: 'stopped',
    );
  }
}

Future<void> main() async {
  final simulator = await RaccoonControlClient.discover();
  simulator?.close();
  final headless = Platform.environment['RACCOON_MCP_HEADLESS'] == '1';

  test(
    'on the simulator\'s board',
    () async {
      final client = await connect('simulator');
      try {
        await session(client, 'simulator');
      } finally {
        await client.close();
      }
    },
    skip: simulator == null ? 'no Raccoon Simulator is open' : false,
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'headless, no window',
    () async {
      final client = await connect('headless');
      try {
        await session(client, 'headless');
      } finally {
        await client.close();
      }
    },
    skip: headless ? false : 'set RACCOON_MCP_HEADLESS=1 to run it',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

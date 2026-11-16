import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:raccoon_mcp/src/raccoon_bridge.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';

/// One tool: its name, what it tells the agent, and its parameters as JSON
/// Schema.
final class RaccoonTool {
  const RaccoonTool(
    this.name,
    this.description,
    this.properties, {
    this.required = const [],
    this.readOnly = false,
  });

  final String name;
  final String description;
  final Map<String, Object?> properties;
  final List<String> required;

  /// Whether it changes nothing: listing, looking, reading.
  final bool readOnly;

  Map<String, Object?> get inputSchema => {
    'type': 'object',
    'properties': properties,
    if (required.isNotEmpty) 'required': required,
  };
}

const _device = {
  'type': 'string',
  'description':
      'The Raccoon device the app runs on: raccoon-phone, raccoon-tablet, '
      'raccoon-desktop, raccoon, or the part after raccoon- (phone). Not '
      'needed while one app runs.',
};

const _app = {
  'type': 'string',
  'description':
      'The app\'s project name (its pubspec name), when several apps run on '
      'the device.',
};

const _x = {'type': 'number', 'description': 'Logical pixels from the left.'};
const _y = {'type': 'number', 'description': 'Logical pixels from the top.'};

/// The tools, in the order a client lists them; names as in issue #48.
const raccoonTools = [
  RaccoonTool(
    'list_devices',
    'Lists the Raccoon devices registered with the Flutter tool, each with '
        'its logical size and pixel ratio, and the apps running on each: '
        'name, size, who started it, whether it hot reloads, its VM service. '
        'Says whether a Raccoon Simulator serves them (host: simulator, a '
        'person sees the board) or this process runs them alone (host: '
        'headless).',
    {},
    readOnly: true,
  ),
  RaccoonTool(
    'run',
    'Runs a Flutter project on a Raccoon device, as flutter run -d <device> '
        '--machine, and returns once the app has drawn: its name, size and '
        'VM service, and how long it took. With a simulator open the app '
        'shows on its board. An app already running there is returned as it '
        'is. Run one device after another, or in parallel: runs of one '
        'project build in turn.',
    {
      'project': {
        'type': 'string',
        'description':
            'The Flutter project\'s folder, absolute or from where this '
            'server runs.',
      },
      'device': {
        'type': 'string',
        'description':
            'raccoon-phone (390x844 at 3x, the default), raccoon-tablet '
            '(820x1180 at 2x), raccoon-desktop (1280x800 at 1x), or another '
            'registered Raccoon device.',
      },
      'target': {
        'type': 'string',
        'description': 'The entry point, lib/main.dart when not given.',
      },
    },
    required: ['project'],
  ),
  RaccoonTool('stop', 'Stops an app and its runner.', {
    'device': _device,
    'app': _app,
  }),
  RaccoonTool(
    'hot_reload',
    'Hot reloads an app started through run (or the simulator\'s Run): its '
        'code changed on disk, its state stays. Returns once it drew after '
        'the reload; fails with the compiler\'s message.',
    {'device': _device, 'app': _app},
  ),
  RaccoonTool(
    'hot_restart',
    'Hot restarts an app started through run: its code reloads and its '
        'state starts over. Returns once it drew after the restart.',
    {'device': _device, 'app': _app},
  ),
  RaccoonTool(
    'screenshot',
    'The app\'s frame once it settles, as a PNG, pixel-exact: the size of '
        'the device in physical pixels (1170x2532 for raccoon-phone) unless '
        'scaled. logical: true gives one image pixel per logical pixel, the '
        'space every coordinate here is in, and a smaller image.',
    {
      'device': _device,
      'app': _app,
      'logical': {
        'type': 'boolean',
        'description': 'Scale to logical pixels (1 / pixel ratio).',
      },
      'scale': {
        'type': 'number',
        'description': 'Scale each side by this, above 0 and at most 1.',
      },
    },
    readOnly: true,
  ),
  RaccoonTool(
    'tap',
    'Taps at a point, in logical pixels, as a finger does.',
    {'device': _device, 'app': _app, 'x': _x, 'y': _y},
    required: ['x', 'y'],
  ),
  RaccoonTool(
    'long_press',
    'Presses at a point, in logical pixels, for hold_ms (650 unless said), '
        'past Flutter\'s long press.',
    {
      'device': _device,
      'app': _app,
      'x': _x,
      'y': _y,
      'hold_ms': {'type': 'number', 'description': 'How long to hold.'},
    },
    required: ['x', 'y'],
  ),
  RaccoonTool(
    'drag',
    'Drags a finger from one point to another in logical pixels over '
        'duration_ms (300 unless said), then lifts it: fast and short is a '
        'fling, slow a pan.',
    {
      'device': _device,
      'app': _app,
      'from_x': _x,
      'from_y': _y,
      'to_x': _x,
      'to_y': _y,
      'duration_ms': {'type': 'number', 'description': 'How long it takes.'},
    },
    required: ['from_x', 'from_y', 'to_x', 'to_y'],
  ),
  RaccoonTool(
    'scroll',
    'Turns a mouse wheel over a point by dx, dy logical pixels: positive dy '
        'scrolls the content down, as a wheel turned towards you does.',
    {
      'device': _device,
      'app': _app,
      'x': _x,
      'y': _y,
      'dx': {'type': 'number', 'description': 'Horizontal, logical pixels.'},
      'dy': {'type': 'number', 'description': 'Vertical, logical pixels.'},
    },
    required: ['x', 'y'],
  ),
  RaccoonTool(
    'type_text',
    'Types text into the text field that has the focus, in place of its '
        'selection, as an input method does. Tap the field first.',
    {
      'device': _device,
      'app': _app,
      'text': {'type': 'string', 'description': 'What to type.'},
    },
    required: ['text'],
  ),
  RaccoonTool(
    'press_key',
    'Presses and releases a key, with modifiers held around it: enter, '
        'escape, backspace, tab, space, delete, home, end, page_up, '
        'page_down, arrow_left, arrow_right, arrow_up, arrow_down, or one '
        'character.',
    {
      'device': _device,
      'app': _app,
      'key': {'type': 'string', 'description': 'The key.'},
      'modifiers': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': 'Held around it: shift, control, alt, meta.',
      },
    },
    required: ['key'],
  ),
  RaccoonTool(
    'logs',
    'The app\'s log: its prints and errors (source app), the runner\'s own '
        'lines with their timings (source runner, they start with the '
        'raccoon emoji), and for a run started here the Flutter tool\'s '
        '(source tool: build steps, reloads, compile errors). Filtered by '
        'source, a substring or a regular expression, the last 100 unless '
        'said.',
    {
      'device': _device,
      'app': _app,
      'source': {
        'type': 'string',
        'enum': ['all', 'app', 'runner', 'tool'],
      },
      'contains': {'type': 'string', 'description': 'Lines with this.'},
      'pattern': {
        'type': 'string',
        'description': 'Lines matching this regular expression.',
      },
      'last': {
        'type': 'number',
        'description': 'How many of the last lines, 0 for all.',
      },
    },
    readOnly: true,
  ),
  RaccoonTool(
    'resize',
    'Gives the app a logical size and pixel ratio, as the board\'s handle '
        'does, and returns once it drew at that size. On the simulator the '
        'app starts at that size on its next run too.',
    {
      'device': _device,
      'app': _app,
      'width': {'type': 'number', 'description': 'Logical width.'},
      'height': {'type': 'number', 'description': 'Logical height.'},
      'pixel_ratio': {
        'type': 'number',
        'description': 'Physical pixels per logical one; kept when not given.',
      },
    },
    required: ['width', 'height'],
  ),
];

/// Registers [raccoonTools] on [server], each calling [bridge].
void registerRaccoonTools(McpServer server, RaccoonBridge bridge) {
  for (final tool in raccoonTools) {
    server.registerTool(
      tool.name,
      description: tool.description,
      inputSchema: JsonSchema.fromJson(tool.inputSchema) as JsonObject,
      annotations: ToolAnnotations(readOnlyHint: tool.readOnly),
      callback: (args, extra) => callTool(bridge, tool.name, args),
    );
  }
}

/// [name] with [args] through [bridge], as a tool result: a screenshot as
/// an image beside its sizes, the rest as JSON, a failure as an error.
Future<CallToolResult> callTool(
  RaccoonBridge bridge,
  String name,
  Map<String, dynamic> args,
) async {
  final Map<String, Object?> result;
  try {
    result = await bridge.call(name, args.cast<String, Object?>());
  } on RaccoonControlError catch (error) {
    return CallToolResult(
      content: [TextContent(text: '$error')],
      isError: true,
    );
  } on Object catch (error) {
    return CallToolResult(
      content: [TextContent(text: 'failed: $error')],
      isError: true,
    );
  }
  if (result['png'] case final String png) {
    final rest = {...result}..remove('png');
    return CallToolResult(
      content: [
        ImageContent(data: png, mimeType: 'image/png'),
        TextContent(text: jsonEncode(rest)),
      ],
      structuredContent: rest,
    );
  }
  return CallToolResult.fromStructuredContent(result);
}

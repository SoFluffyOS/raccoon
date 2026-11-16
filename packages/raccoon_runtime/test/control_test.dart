import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:raccoon/raccoon.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

/// A runner stand-in on a Unix socket: draws a frame of the size it is
/// given, in one colour, and keeps what the client sent.
final class _Runner {
  _Runner._(this._server) {
    _server.listen((socket) {
      _client = socket;
      socket.listen((bytes) {
        for (final payload in _unframer.add(bytes)) {
          final message = ClientMessage.fromBuffer(payload);
          received.add(message);
          if (message.hasResize()) {
            width = message.resize.width;
            height = message.resize.height;
            draw();
          }
          if (message.hasHello()) draw();
        }
      });
      send(RunnerMessage(hello: RunnerHello(protocolVersion: 1, pid: 7)));
      _connected.complete();
    });
  }

  static Future<_Runner> start(String path) async => _Runner._(
    await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    ),
  );

  final ServerSocket _server;
  final _unframer = MessageUnframer();
  final _connected = Completer<void>();
  final received = <ClientMessage>[];
  Socket? _client;
  var width = 6;
  var height = 4;
  var _sequence = 0;

  Future<void> get connected => _connected.future;

  var _stopped = false;

  void send(RunnerMessage message) {
    if (_stopped) return;
    _client?.add(MessageFraming.frame(message.writeToBuffer()));
  }

  /// A frame of the current size, red in BGRA.
  void draw() {
    final pixels = Uint8List(width * height * 4);
    for (var i = 0; i < pixels.length; i += 4) {
      pixels
        ..[i + 2] = 0xFF
        ..[i + 3] = 0xFF;
    }
    send(
      RunnerMessage(
        frame: Frame(
          sequence: Int64(++_sequence),
          width: width,
          height: height,
          rowBytes: width * 4,
          pixels: pixels,
        ),
      ),
    );
  }

  List<PointerEvent> get pointers => [
    for (final message in received)
      if (message.hasPointer()) message.pointer,
  ];

  Future<void> stop() async {
    _stopped = true;
    await _client?.close();
    await _server.close();
  }
}

final class _App implements RaccoonControlApp {
  _App(this.name, this.client, this.size);

  @override
  final String name;

  @override
  final RunnerClient client;

  @override
  DeviceSize size;

  final lines = <DeviceLogLine>[];
  var stopped = false;
  var reloads = 0;

  @override
  String get startedBy => 'agent';

  @override
  String? get vmServiceUri => 'http://127.0.0.1:1/x/';

  @override
  bool canReload = true;

  @override
  bool get releasesGpuFrames => true;

  @override
  Future<void> hotReload() async => reloads++;

  @override
  Future<void> hotRestart() async => reloads += 10;

  @override
  Future<void> stop() async => stopped = true;

  @override
  Future<void> resize(DeviceSize size) async {
    this.size = size;
    client.resize(
      (size.width * size.pixelRatio).round(),
      (size.height * size.pixelRatio).round(),
      size.pixelRatio,
    );
  }

  @override
  List<DeviceLogLine> logLines() => lines;
}

final class _Host implements RaccoonControlHost {
  final running = <RaccoonControlApp>[];
  final said = <String>[];

  @override
  String get kind => 'test';

  @override
  List<RaccoonControlDevice> devices() => [
    RaccoonControlDevice.of('raccoon'),
    RaccoonControlDevice.of('raccoon-phone'),
    RaccoonControlDevice.of('raccoon-tablet', size: '800x1200@2'),
  ];

  @override
  List<RaccoonControlApp> apps() => running;

  @override
  Future<RaccoonControlApp> run(
    String project, {
    required String device,
    String? target,
  }) async => running.firstWhere(
    (app) => app.name == RaccoonControlDevice.appNameOn(project, device),
  );

  @override
  void announce(RaccoonControlApp? app, String action) =>
      said.add('${app?.name ?? '-'}: $action');
}

void main() {
  late Directory temp;
  late _Runner runner;
  late RunnerClient client;
  late _Host host;
  late _App phone;
  late RaccoonControl control;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('raccoon_control');
    final path = p.join(temp.path, 'hello@phone.sock');
    runner = await _Runner.start(path);
    client = await RunnerClient.connect(UnixSocketEndpoint(path));
    await runner.connected;
    await client.hello;
    // 2 x 4/3 logical pixels at 3x: the runner's 6 x 4.
    phone = _App('hello@phone', client, (
      width: 2,
      height: 4 / 3,
      pixelRatio: 3,
    ));
    host = _Host()..running.add(phone);
    control = RaccoonControl(host);
  });

  tearDown(() async {
    await runner.stop();
    await client.close();
    temp.deleteSync(recursive: true);
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  test('list_devices gives each device its size and its apps', () async {
    final result = await control.call('list_devices', {});
    expect(result['host'], 'test');
    final devices = result['devices'] as List;
    expect(
      [for (final d in devices) (d as Map)['id']],
      ['raccoon', 'raccoon-phone', 'raccoon-tablet'],
    );
    final phoneDevice = devices[1] as Map;
    expect(phoneDevice['size'], {
      'width': 390,
      'height': 844,
      'pixel_ratio': 3,
    });
    expect(
      (phoneDevice['apps'] as List).single,
      containsPair('name', 'hello@phone'),
    );
    expect((devices[2] as Map)['size'], {
      'width': 800,
      'height': 1200,
      'pixel_ratio': 2,
    });
    expect((devices[0] as Map)['size'], isNull);
  });

  test('a tap goes out in physical pixels, and the host says so', () async {
    await control.call('tap', {'device': 'raccoon-phone', 'x': 1, 'y': 0.5});
    await settle();
    final [down, up] = runner.pointers;
    expect(
      (down.phase, down.x, down.y),
      (PointerPhase.POINTER_PHASE_DOWN, 3, 1.5),
    );
    expect((up.phase, up.buttons.toInt()), (PointerPhase.POINTER_PHASE_UP, 0));
    expect(down.pointerId, up.pointerId);
    expect(host.said, ['hello@phone: tap 1, 0.5']);
  });

  test('with one app running, a call needs no device', () async {
    await control.call('scroll', {'x': 1, 'y': 1, 'dy': 10});
    await settle();
    final [wheel] = runner.pointers;
    expect(
      (wheel.scrollDeltaY, wheel.device),
      (30, PointerDevice.POINTER_DEVICE_MOUSE),
    );
  });

  test('a point outside the app, a bad key and an unknown method are the '
      'caller\'s to fix', () async {
    Matcher fails(String code) =>
        throwsA(isA<RaccoonControlError>().having((e) => e.code, 'code', code));
    expect(control.call('tap', {'x': 5, 'y': 1}), fails('bad_params'));
    expect(control.call('tap', {'x': 1}), fails('bad_params'));
    expect(control.call('press_key', {'key': 'hyper'}), fails('bad_params'));
    expect(control.call('fly', {}), fails('unknown_method'));
    expect(
      control.call('tap', {'device': 'tablet', 'x': 1, 'y': 1}),
      fails('no_app'),
    );
  });

  test('two apps on one device need the app named', () async {
    host.running.add(_App('other@phone', client, phone.size));
    expect(
      control.call('tap', {'device': 'phone', 'x': 1, 'y': 1}),
      throwsA(
        isA<RaccoonControlError>().having((e) => e.code, 'code', 'ambiguous'),
      ),
    );
    final result = await control.call('tap', {
      'device': 'phone',
      'app': 'hello',
      'x': 1,
      'y': 1,
    });
    expect(result['app'], 'hello@phone');
  });

  test('a key goes down and up between its modifiers', () async {
    await control.call('press_key', {
      'key': 'a',
      'modifiers': ['ctrl'],
    });
    await settle();
    final keys = [
      for (final message in runner.received)
        if (message.hasKey()) (message.key.kind, message.key.physical.toInt()),
    ];
    expect(keys, [
      (KeyKind.KEY_KIND_DOWN, RaccoonKey.control.physical),
      (KeyKind.KEY_KIND_DOWN, 0x00070004),
      (KeyKind.KEY_KIND_UP, 0x00070004),
      (KeyKind.KEY_KIND_UP, RaccoonKey.control.physical),
    ]);
  });

  test('with shift held, a letter types its capital', () async {
    await control.call('press_key', {
      'key': 'a',
      'modifiers': ['shift'],
    });
    await settle();
    final typed = [
      for (final message in runner.received)
        if (message.hasKey() && message.key.character.isNotEmpty)
          message.key.character,
    ];
    expect(typed, ['A']);
  });

  test(
    'a screenshot is the settled frame as a PNG, scaled on request',
    () async {
      final full = await control.call('screenshot', {});
      expect((full['width'], full['height'], full['pixel_ratio']), (6, 4, 3.0));
      final image = img.decodePng(base64Decode(full['png'] as String))!;
      expect((image.width, image.height), (6, 4));
      final pixel = image.getPixel(0, 0);
      expect((pixel.r, pixel.g, pixel.b), (255, 0, 0));

      final logical = await control.call('screenshot', {'logical': true});
      final small = img.decodePng(base64Decode(logical['png'] as String))!;
      expect((small.width, small.height), (2, 1));
      expect(logical['logical_width'], 2);
    },
  );

  test('resize gives the app its size and waits for a frame at it', () async {
    final result = await control.call('resize', {
      'width': 5,
      'height': 3,
      'pixel_ratio': 2,
    });
    expect((result['app'] as Map)['size'], {
      'width': 5,
      'height': 3,
      'pixel_ratio': 2,
    });
    expect((client.latestFrame!.width, client.latestFrame!.height), (10, 6));
  });

  test('logs filter by source, text and count', () async {
    phone.lines.addAll([
      DeviceLogLine.output('12:00:00.000 🦝 first frame 236 ms after launch'),
      DeviceLogLine.output('flutter: hello'),
      DeviceLogLine.output('flutter: hello again'),
      const DeviceLogLine(DeviceLogSource.tool, 'Reloaded 1 of 600 libraries'),
    ]);
    List<String> texts(Map<String, Object?> result) => [
      for (final line in result['lines'] as List)
        (line as Map)['text'] as String,
    ];
    expect(texts(await control.call('logs', {'source': 'runner'})), [
      '12:00:00.000 🦝 first frame 236 ms after launch',
    ]);
    expect(
      texts(await control.call('logs', {'contains': 'hello', 'last': 1})),
      ['flutter: hello again'],
    );
    expect(texts(await control.call('logs', {'pattern': r'Reloaded \d'})), [
      'Reloaded 1 of 600 libraries',
    ]);
    final all = await control.call('logs', {});
    expect((all['matched'], all['total']), (4, 4));
  });

  test('a run not started here has no hot reload', () async {
    phone.canReload = false;
    expect(
      control.call('hot_reload', {}),
      throwsA(
        isA<RaccoonControlError>().having((e) => e.code, 'code', 'unsupported'),
      ),
    );
    phone.canReload = true;
    await control.call('hot_restart', {});
    expect(phone.reloads, 10);
  });

  group('the endpoint', () {
    late RaccoonControlServer server;
    late String folder;

    setUp(() async {
      folder = p.join(temp.path, 'control');
      server = await RaccoonControlServer.start(
        control,
        kind: 'simulator',
        directory: folder,
      );
    });

    tearDown(() => server.close());

    test('serves the calls to a client that found its file', () async {
      final client = await RaccoonControlClient.discover(directory: folder);
      expect(client, isNotNull);
      final found = client!;
      try {
        expect(found.host, 'simulator');
        expect((await found.hello())['methods'], RaccoonControl.methods);
        final result = await found.call('tap', {'x': 1, 'y': 1});
        expect(result['app'], 'hello@phone');
        expect(
          found.call('tap', {'device': 'tablet', 'x': 1, 'y': 1}),
          throwsA(
            isA<RaccoonControlError>().having((e) => e.code, 'code', 'no_app'),
          ),
        );
      } finally {
        found.close();
      }
    });

    test('listens on loopback, with a file only its user reads', () async {
      expect(server.uri.host, '127.0.0.1');
      final json = jsonDecode(server.file.readAsStringSync()) as Map;
      expect(json['token'], server.token);
      if (!Platform.isWindows) {
        expect(server.file.statSync().mode & 0x3F, 0);
        expect(Directory(folder).statSync().mode & 0x3F, 0);
      }
    });

    test('turns away a wrong token, none, and a browser', () async {
      final http = HttpClient();
      Future<int> status(Map<String, String> headers) async {
        final request = await http.postUrl(server.uri.resolve('/v1/call'));
        headers.forEach(request.headers.set);
        request.write(jsonEncode({'method': 'list_devices'}));
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      }

      try {
        expect(await status({}), HttpStatus.unauthorized);
        expect(
          await status({'authorization': 'Bearer nope'}),
          HttpStatus.unauthorized,
        );
        expect(
          await status({
            'authorization': 'Bearer ${server.token}',
            'origin': 'http://example.com',
          }),
          HttpStatus.forbidden,
        );
        expect(
          await status({'authorization': 'Bearer ${server.token}'}),
          HttpStatus.ok,
        );
      } finally {
        http.close(force: true);
      }
    });

    test('takes its file away when it closes', () async {
      await server.close();
      expect(server.file.existsSync(), isFalse);
      expect(await RaccoonControlClient.discover(directory: folder), isNull);
    });
  });
}

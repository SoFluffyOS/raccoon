// Drives the real runner with the example app: frame pixels, then a tap that
// turns the box green. Skipped when the runner or its inputs are not built;
// see native/raccoon_runner/tool/render_example.sh.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:path/path.dart' as p;
import 'package:raccoon/raccoon.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

const _blue = (r: 0x1E, g: 0x88, b: 0xE5);
const _red = (r: 0xE5, g: 0x39, b: 0x35);
const _green = (r: 0x43, g: 0xA0, b: 0x47);
const _purple = (r: 0x8E, g: 0x24, b: 0xAA);
const _orange = (r: 0xFB, g: 0x8C, b: 0x00);
const _white = (r: 0xFF, g: 0xFF, b: 0xFF);

/// example/camera's picture line: the verdict on the test pattern's bars,
/// the colours seen where they are, and the picture's path.
final _pictureLine = RegExp(
  r'^picture (bars \w+) left=(\S+) right=(\S+) (.*)$',
);

/// A PNG of [width] x [height], 8-bit RGB, each pixel [rgb] of its position.
Uint8List _png(int width, int height, List<int> Function(int x, int y) rgb) {
  final crcTable = List<int>.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = c & 1 == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });
  List<int> chunk(String type, List<int> data) {
    final body = [...ascii.encode(type), ...data];
    var crc = 0xFFFFFFFF;
    for (final byte in body) {
      crc = crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    crc ^= 0xFFFFFFFF;
    List<int> word(int v) => [
      v >> 24 & 0xFF,
      v >> 16 & 0xFF,
      v >> 8 & 0xFF,
      v & 0xFF,
    ];
    return [...word(data.length), ...body, ...word(crc)];
  }

  final rows = <int>[
    for (var y = 0; y < height; y++) ...[
      0, // no filter
      for (var x = 0; x < width; x++) ...rgb(x, y),
    ],
  ];
  return Uint8List.fromList([
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    ...chunk('IHDR', [
      ...[0, 0, width >> 8, width & 0xFF],
      ...[0, 0, height >> 8, height & 0xFF],
      8, 2, 0, 0, 0, // 8 bits, RGB, deflate, no filter, no interlace
    ]),
    ...chunk('IDAT', zlib.encode(rows)),
    ...chunk('IEND', []),
  ]);
}

/// The colour at ([x], [y]), whichever byte order the host rasters in.
({int r, int g, int b}) _pixel(Frame frame, int x, int y) {
  final offset = y * frame.rowBytes + x * 4;
  final bytes = frame.pixels;
  return switch (frame.format) {
    PixelFormat.PIXEL_FORMAT_RGBA8888 => (
      r: bytes[offset],
      g: bytes[offset + 1],
      b: bytes[offset + 2],
    ),
    _ => (r: bytes[offset + 2], g: bytes[offset + 1], b: bytes[offset]),
  };
}

/// A JSON method-channel reply, as flutter/platform expects: a one-element
/// array holding the result.
Uint8List _jsonReply(Object? result) =>
    Uint8List.fromList(utf8.encode(jsonEncode([result])));

String? _firstExisting(Iterable<String> candidates) =>
    candidates.where((c) => c.isNotEmpty && File(c).existsSync()).firstOrNull;

void main() {
  final workspace = p.normalize(p.join(Directory.current.path, '..', '..'));
  final runnerDir = p.join(workspace, 'native', 'raccoon_runner');
  final environment = Platform.environment;
  final binary = _firstExisting([
    environment['RACCOON_RUNNER'] ?? '',
    p.join(
      runnerDir,
      'build',
      Platform.isWindows ? 'raccoon_runner.exe' : 'raccoon_runner',
    ),
  ]);
  final assets = p.join(
    runnerDir,
    'example',
    'hello',
    'build',
    'flutter_assets',
  );
  final sdk = _sdkRoot(environment);
  final revision = switch (sdk) {
    final root? => RuntimeStore.revisionOfSdk(root),
    null => null,
  };
  final engineDir =
      environment['RACCOON_ENGINE_DIR'] ??
      switch (revision) {
        final rev? =>
          RuntimeStore.forHost(environment).installed(rev)?.directory,
        null => null,
      };
  final icu = _firstExisting([
    environment['RACCOON_ICU'] ?? '',
    if (sdk != null) RuntimeStore.icuDataOfSdk(sdk),
  ]);
  final ready =
      binary != null &&
      engineDir != null &&
      icu != null &&
      Directory(assets).existsSync();

  test(
    'renders the example app and reacts to a tap',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      try {
        final hello = await client.hello.timeout(const Duration(seconds: 10));
        expect(hello.protocolVersion, RaccoonProtocol.version);
        expect(hello.pid, runner.pid);
        expect(client.pid, runner.pid);

        final frame = await client.frames.first.timeout(
          const Duration(seconds: 15),
        );
        expect(frame.width, 800);
        expect(frame.height, 600);
        expect(frame.format, isNot(PixelFormat.PIXEL_FORMAT_UNSPECIFIED));
        expect(_pixel(frame, 5, 5), _blue);
        expect(_pixel(frame, 400, 300), _red);

        final vmService = await runner.vmServiceUri.timeout(
          const Duration(seconds: 10),
        );
        expect(vmService, startsWith('http://'));

        for (final (phase, buttons) in [
          (PointerPhase.POINTER_PHASE_DOWN, 1),
          (PointerPhase.POINTER_PHASE_UP, 0),
        ]) {
          client.sendPointer(
            PointerEvent(
              phase: phase,
              x: 400,
              y: 300,
              buttons: Int64(buttons),
              device: PointerDevice.POINTER_DEVICE_MOUSE,
              pointerId: 1,
            ),
          );
        }
        final toggled = await client.frames
            .firstWhere((f) => _pixel(f, 400, 300) == _green)
            .timeout(const Duration(seconds: 10));
        expect(_pixel(toggled, 5, 5), _blue);
        // A Windows socket carries no handles, so frames ride inline there.
        expect(
          client.sharedFrames,
          Platform.isWindows ? 0 : greaterThan(0),
          reason: 'frames should travel through shared buffers where they can',
        );
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready
            ? false
            : 'build the runner and example first: $binary / $engineDir / $icu',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'a sized device starts at its logical size, in pixels times its ratio',
    () async {
      // The helper's --size is logical, as raccoon-phone's 390x844@3 is;
      // the runner takes pixels. A client that never resizes sees the size
      // the runner started at.
      final temp = Directory.systemTemp.createTempSync('raccoon_size');
      final helper = p.join(runnerDir, 'tool', 'raccoon-device');
      final helperEnvironment = {
        'RACCOON_RUNNER': binary!,
        if (sdk != null) 'FLUTTER_ROOT': sdk,
        'XDG_DATA_HOME': p.join(temp.path, 'data'),
        'XDG_RUNTIME_DIR': temp.path,
        'TMPDIR': '${temp.path}/',
      };
      final install = await Process.run(helper, [
        'install',
        assets,
        'sized',
      ], environment: helperEnvironment);
      expect(install.exitCode, 0, reason: '${install.stderr}');
      final run = await Process.start(helper, [
        'run',
        '--size',
        '200x150@2',
        'sized',
      ], environment: helperEnvironment);
      final socket = File(p.join(temp.path, 'raccoon', 'sized.sock'));
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!socket.existsSync() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final client = await RunnerClient.connect(
          UnixSocketEndpoint(socket.path),
        );
        try {
          final frame = await client.frames.first.timeout(
            const Duration(seconds: 15),
          );
          expect((frame.width, frame.height), (400, 300));
        } finally {
          client.shutdown();
          await client.close();
        }
      } finally {
        run.kill();
        await run.exitCode;
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'the helper runs in Git Bash on Windows',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  // #119: an engine that can't be downloaded stops the run with a word on
  // why, not with the runner's usage text.
  test(
    'a run whose engine can\'t be downloaded says so',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_offline');
      final helper = p.join(runnerDir, 'tool', 'raccoon-device');
      final environment = {
        'RACCOON_RUNNER': binary!,
        if (sdk != null) 'FLUTTER_ROOT': sdk,
        'XDG_DATA_HOME': p.join(temp.path, 'data'),
        'XDG_RUNTIME_DIR': temp.path,
        'TMPDIR': '${temp.path}/',
        // No engine cached, and no way to fetch one.
        'RACCOON_ENGINE_CACHE': p.join(temp.path, 'engines'),
        'https_proxy': 'http://127.0.0.1:9',
        'HTTPS_PROXY': 'http://127.0.0.1:9',
      };
      try {
        final install = await Process.run(helper, [
          'install',
          assets,
          'offline',
        ], environment: environment);
        expect(install.exitCode, 0, reason: '${install.stderr}');
        final run = await Process.run(helper, [
          'run',
          'offline',
        ], environment: environment).timeout(const Duration(seconds: 60));
        expect(run.exitCode, isNot(0));
        expect(
          '${run.stderr}',
          contains('could not download the Flutter engine'),
        );
        expect('${run.stderr}', isNot(contains('usage:')));

        // A runner that isn't there says so too, the engine found as usual.
        final missing = await Process.run(
          helper,
          ['run', 'offline'],
          environment: {
            for (final MapEntry(:key, :value) in environment.entries)
              if (!key.toLowerCase().contains('proxy') &&
                  key != 'RACCOON_ENGINE_CACHE')
                key: value,
            'RACCOON_RUNNER': p.join(temp.path, 'no_runner'),
          },
        ).timeout(const Duration(seconds: 60));
        expect(missing.exitCode, isNot(0));
        expect('${missing.stderr}', contains('no runner at'));

        // And an app that was never installed.
        final absent = await Process.run(helper, [
          'run',
          'never_installed',
        ], environment: environment).timeout(const Duration(seconds: 60));
        expect(absent.exitCode, isNot(0));
        expect(
          '${absent.stderr}',
          contains('never_installed is not installed'),
        );
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'the helper runs in Git Bash on Windows',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  // #120: pub encodes a relative rootUri (my%20libs); the helper looked for
  // the encoded folder and skipped the package without a word.
  test(
    'a hook package in a folder with a space is found',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_space');
      final helper = p.join(runnerDir, 'tool', 'raccoon-device');
      final project = Directory(p.join(temp.path, 'app'))..createSync();
      final hooked = Directory(p.join(temp.path, 'my libs', 'hooked'))
        ..createSync(recursive: true);
      File(p.join(hooked.path, 'hook', 'build.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('void main(List<String> args) {}\n');
      File(
        p.join(hooked.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: hooked\n');
      File(
        p.join(project.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: app\n');
      File(p.join(project.path, 'lib', 'main.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('void main() {}\n');
      File(p.join(project.path, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'configVersion': 2,
            'packages': [
              {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
              {
                'name': 'hooked',
                'rootUri': '../../my%20libs/hooked',
                'packageUri': 'lib/',
              },
            ],
          }),
        );
      final bundle = Directory(p.join(project.path, 'build', 'flutter_assets'))
        ..createSync(recursive: true);
      try {
        final install = await Process.run(
          helper,
          ['install', bundle.path, 'space_hook'],
          environment: {
            'RACCOON_RUNNER': binary!,
            if (sdk != null) 'FLUTTER_ROOT': sdk,
            'XDG_DATA_HOME': p.join(temp.path, 'data'),
            'XDG_RUNTIME_DIR': temp.path,
            'TMPDIR': '${temp.path}/',
          },
        );
        // Built or not, the hook was found: the install says something
        // about native assets rather than nothing.
        expect('${install.stderr}', contains('native assets'));
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'the helper runs in Git Bash on Windows',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // #118: a socket path must fit in 104 bytes on macOS. An app whose key
  // doesn't fit runs under a shorter socket name, its key in a .name file.
  test(
    'an app whose name is too long for a socket path still runs',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_long');
      final helper = p.join(runnerDir, 'tool', 'raccoon-device');
      final name = 'a_flutter_app_${'with_a_very_long_name_' * 4}x';
      final environment = {
        'RACCOON_RUNNER': binary!,
        if (sdk != null) 'FLUTTER_ROOT': sdk,
        'XDG_DATA_HOME': p.join(temp.path, 'data'),
        'XDG_RUNTIME_DIR': temp.path,
        'TMPDIR': '${temp.path}/',
      };
      final install = await Process.run(helper, [
        'install',
        assets,
        name,
      ], environment: environment);
      expect(install.exitCode, 0, reason: '${install.stderr}');
      final run = await Process.start(helper, [
        'run',
        name,
      ], environment: environment);
      final output = <String>[];
      run.stderr.transform(utf8.decoder).listen(output.add);
      run.stdout.drain<void>().ignore();
      try {
        final discovery = RunnerDiscovery(p.join(temp.path, 'raccoon'));
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (discovery.list().isEmpty && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final found = discovery.list();
        expect(found, hasLength(1), reason: output.join());
        expect(RunnerDiscovery.appNameOf(found.single), name);
        final client = await RunnerClient.connect(found.single);
        try {
          await client.frames.first.timeout(const Duration(seconds: 15));
        } finally {
          client.shutdown();
          await client.close();
        }
      } finally {
        run.kill();
        await run.exitCode;
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'the helper runs in Git Bash on Windows',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  final nativeAssetsApp = p.join(runnerDir, 'example', 'native_assets_app');
  final nativeAssetsBundle = p.join(nativeAssetsApp, 'build', 'flutter_assets');
  test(
    'a code asset from a build hook loads, on macOS and on Linux',
    () async {
      // native_add's hook compiles add() in C. The tool builds the bundle
      // for the Linux device it thinks Raccoon is, without running hooks for
      // this host; the helper runs them and installs the library (#53, #57).
      final temp = Directory.systemTemp.createTempSync('raccoon_native');
      final helper = p.join(runnerDir, 'tool', 'raccoon-device');
      final data = p.join(temp.path, 'data');
      final helperEnvironment = {
        'RACCOON_RUNNER': binary!,
        if (sdk != null) 'FLUTTER_ROOT': sdk,
        'XDG_DATA_HOME': data,
        'XDG_RUNTIME_DIR': temp.path,
        'TMPDIR': '${temp.path}/',
      };
      final hadLinux = Directory(p.join(nativeAssetsApp, 'linux')).existsSync();
      // An iOS Runner's Firebase config, which the app's bundle carries on
      // macOS.
      final ios = Directory(p.join(nativeAssetsApp, 'ios'));
      final hadIos = ios.existsSync();
      if (!hadIos) {
        File(p.join(ios.path, 'Runner', 'GoogleService-Info.plist'))
          ..createSync(recursive: true)
          ..writeAsStringSync('<plist><dict/></plist>');
      }
      final ProcessResult install;
      try {
        install = await Process.run(helper, [
          'install',
          nativeAssetsBundle,
          'native_assets_app',
        ], environment: helperEnvironment);
      } finally {
        if (!hadIos) ios.deleteSync(recursive: true);
      }
      expect(install.exitCode, 0, reason: '${install.stderr}');
      expect('${install.stderr}', contains('1 for this host'));
      // The Linux target's engine copy goes again.
      expect(
        Directory(p.join(nativeAssetsApp, 'linux')).existsSync(),
        hadLinux,
      );
      final manifest =
          jsonDecode(
                File(
                  p.join(
                    data,
                    'raccoon',
                    'apps',
                    'native_assets_app',
                    'flutter_assets',
                    'NativeAssetsManifest.json',
                  ),
                ).readAsStringSync(),
              )
              as Map;
      final paths = [
        for (final assets in (manifest['native-assets'] as Map).values)
          for (final path in (assets as Map).values) (path as List).last,
      ];
      expect(paths, hasLength(1));
      expect(File('${paths.single}').existsSync(), isTrue);

      final run = await Process.start(helper, [
        'run',
        'native_assets_app',
      ], environment: helperEnvironment);
      final lines = <String>[];
      run.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(lines.add);
      run.stderr.drain<void>().ignore();
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!lines.any((line) => line.contains('NATIVE:')) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(lines, contains(contains('NATIVE:42')));
        // The app's bundle carries the pubspec's version: 1.2.3+4 (#186).
        if (Platform.isMacOS) {
          final plist =
              File(
                p.join(
                  data,
                  'raccoon',
                  'apps',
                  'native_assets_app',
                  'native_assets_app.app',
                  'Contents',
                  'Info.plist',
                ),
              ).readAsStringSync();
          expect(
            plist,
            contains(
              '<key>CFBundleShortVersionString</key><string>1.2.3</string>',
            ),
          );
          expect(
            plist,
            contains('<key>CFBundleVersion</key><string>4</string>'),
          );
          if (!hadIos) {
            expect(
              File(
                p.join(
                  data,
                  'raccoon',
                  'apps',
                  'native_assets_app',
                  'native_assets_app.app',
                  'Contents',
                  'Resources',
                  'GoogleService-Info.plist',
                ),
              ).existsSync(),
              isTrue,
            );
          }
        }
      } finally {
        run.kill();
        await run.exitCode;
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((
      binary != null &&
          sdk != null &&
          Directory(nativeAssetsBundle).existsSync(),
      Platform.isWindows,
    )) {
      (false, _) => 'build the runner and example/native_assets_app first',
      (_, true) => 'the helper runs in Git Bash on Windows',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
  test(
    'native assets build again only when their inputs change',
    () async {
      // #111: flutter assemble costs seconds per install; the helper keeps
      // what the last one made while the inputs are the same. A hook's own
      // files are inputs, so touching native_add's builds again.
      final temp = Directory.systemTemp.createTempSync('raccoon_native');
      final helper = p.join(runnerDir, 'tool', 'raccoon-device');
      final environment = {
        'RACCOON_RUNNER': binary!,
        if (sdk != null) 'FLUTTER_ROOT': sdk,
        'XDG_DATA_HOME': p.join(temp.path, 'data'),
        'XDG_RUNTIME_DIR': temp.path,
        'TMPDIR': '${temp.path}/',
      };
      Future<String> install() async {
        final result = await Process.run(helper, [
          'install',
          nativeAssetsBundle,
          'native_assets_app',
        ], environment: environment);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        return '${result.stderr}';
      }

      try {
        File(
          p.join(runnerDir, 'example', 'native_add', 'hook', 'build.dart'),
        ).setLastModifiedSync(DateTime.now());
        final built = await install();
        expect(built, contains('1 for this host'));
        expect(built, isNot(contains('unchanged')));

        final again = await install();
        expect(again, contains('1 for this host, unchanged'));

        // A file gone from the hook package, the newest one kept as is:
        // the build is stale.
        final extra = File(
          p.join(runnerDir, 'example', 'native_add', 'hook', 'stale_probe.txt'),
        )..writeAsStringSync('probe');
        extra.setLastModifiedSync(DateTime(2000));
        expect(await install(), contains('1 for this host'));
        extra.deleteSync();
        expect(await install(), isNot(contains('unchanged')));

        // A local package the hook package depends on: its header is an
        // input too.
        expect(await install(), contains('unchanged'));
        File(
          p.join(
            runnerDir,
            'example',
            'native_add_defs',
            'include',
            'native_add_defs.h',
          ),
        ).setLastModifiedSync(DateTime.now());
        expect(await install(), isNot(contains('unchanged')));

        // A source in a folder named build, below the package's own.
        final nested = File(
          p.join(runnerDir, 'example', 'native_add', 'src', 'build', 'x.c'),
        )..createSync(recursive: true);
        try {
          expect(await install(), isNot(contains('unchanged')));
          expect(await install(), contains('unchanged'));
          nested.writeAsStringSync('// changed');
          expect(await install(), isNot(contains('unchanged')));
        } finally {
          nested.parent.deleteSync(recursive: true);
        }

        // A package nested in the hook package, as an example app is, with
        // build output and tool state that change on every run: not inputs.
        final example = Directory(
          p.join(runnerDir, 'example', 'native_add', 'example_probe'),
        );
        File(p.join(example.path, 'pubspec.yaml'))
          ..createSync(recursive: true)
          ..writeAsStringSync('name: example_probe\n');
        try {
          await install();
          expect(await install(), contains('unchanged'));
          File(p.join(example.path, 'build', 'out'))
            ..createSync(recursive: true)
            ..writeAsStringSync('${DateTime.now()}');
          File(p.join(example.path, '.dart_tool', 'state'))
            ..createSync(recursive: true)
            ..writeAsStringSync('${DateTime.now()}');
          expect(await install(), contains('unchanged'));
        } finally {
          example.deleteSync(recursive: true);
        }

        // Flutter's generated ephemeral folders are not inputs either.
        final ephemeral = File(
          p.join(
            runnerDir,
            'example',
            'native_add',
            'linux',
            'flutter',
            'ephemeral',
            'generated',
          ),
        );
        try {
          ephemeral
            ..createSync(recursive: true)
            ..writeAsStringSync('1');
          await install();
          expect(await install(), contains('unchanged'));
          ephemeral.writeAsStringSync('2');
          expect(await install(), contains('unchanged'));
        } finally {
          Directory(
            p.join(runnerDir, 'example', 'native_add', 'linux'),
          ).deleteSync(recursive: true);
        }

        // A folder linked into the package counts through the link.
        final outside = Directory(p.join(temp.path, 'linked_sources'))
          ..createSync();
        final linked = Link(
          p.join(runnerDir, 'example', 'native_add', 'linked_sources'),
        )..createSync(outside.path);
        try {
          await install();
          expect(await install(), contains('unchanged'));
          File(p.join(outside.path, 'y.c')).writeAsStringSync('// new');
          expect(await install(), isNot(contains('unchanged')));
        } finally {
          linked.deleteSync();
        }

        // A dangling link in the package must not cost the app its assets.
        final dangling = Link(
          p.join(runnerDir, 'example', 'native_add', 'dangling_probe'),
        )..createSync(p.join(temp.path, 'nowhere'));
        try {
          expect(await install(), contains('1 for this host'));
        } finally {
          dangling.deleteSync();
        }
        final manifest =
            jsonDecode(
                  File(
                    p.join(
                      temp.path,
                      'data',
                      'raccoon',
                      'apps',
                      'native_assets_app',
                      'flutter_assets',
                      'NativeAssetsManifest.json',
                    ),
                  ).readAsStringSync(),
                )
                as Map;
        final paths = [
          for (final assets in (manifest['native-assets'] as Map).values)
            for (final path in (assets as Map).values) (path as List).last,
        ];
        expect(paths, hasLength(1));
        expect(File('${paths.single}').existsSync(), isTrue);
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example/native_assets_app first',
      (_, true) => 'native assets come from the Flutter tool on Windows',
      _ when !Directory(nativeAssetsBundle).existsSync() =>
        'build example/native_assets_app first',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'an app starts at the size the board saved for it',
    () async {
      // A device that names no size: the helper reads AppSizes, so the app
      // opens as the board left it (#89).
      final temp = Directory.systemTemp.createTempSync('raccoon_size');
      final helper = p.join(runnerDir, 'tool', 'raccoon-device');
      final data = p.join(temp.path, 'data');
      final helperEnvironment = {
        'RACCOON_RUNNER': binary!,
        if (sdk != null) 'FLUTTER_ROOT': sdk,
        'XDG_DATA_HOME': data,
        'XDG_RUNTIME_DIR': temp.path,
        'TMPDIR': '${temp.path}/',
      };
      final install = await Process.run(helper, [
        'install',
        assets,
        'saved',
      ], environment: helperEnvironment);
      expect(install.exitCode, 0, reason: '${install.stderr}');
      AppSizes.forHost(
        helperEnvironment,
      ).save('saved', width: 200, height: 150, pixelRatio: 2);
      final run = await Process.start(helper, [
        'run',
        'saved',
      ], environment: helperEnvironment);
      final socket = File(p.join(temp.path, 'raccoon', 'saved.sock'));
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!socket.existsSync() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final client = await RunnerClient.connect(
          UnixSocketEndpoint(socket.path),
        );
        try {
          final frame = await client.frames.first.timeout(
            const Duration(seconds: 15),
          );
          expect((frame.width, frame.height), (400, 300));
        } finally {
          client.shutdown();
          await client.close();
        }
      } finally {
        run.kill();
        await run.exitCode;
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'the helper runs in Git Bash on Windows',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'on macOS a plugin whose pod needs a cached plugin\'s pod builds',
    () async {
      // plugin_b's pod depends on plugin_a's. The first install builds and
      // caches plugin_a; the second must still find plugin_a's pod to build
      // plugin_b (firebase_analytics on firebase_core, #82).
      final temp = Directory.systemTemp.createTempSync('raccoon_pods');
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      void plugin(
        String name,
        String className, {
        String? needs,
        String? version,
      }) {
        write(
          '$name/pubspec.yaml',
          'name: $name\nversion: 1.0.0\nflutter:\n  plugin:\n    platforms:\n'
              '      macos:\n        pluginClass: $className\n',
        );
        write(
          '$name/macos/$name.podspec',
          "Pod::Spec.new do |s|\n  s.name = '$name'\n  s.version = '1.0.0'\n"
              "  s.summary = '$name'\n  s.homepage = 'https://example.com'\n"
              "  s.license = { :type => 'BSD' }\n  s.author = 'Raccoon'\n"
              "  s.source = { :path => '.' }\n  s.source_files = 'Classes/**/*'\n"
              "  s.dependency 'FlutterMacOS'\n"
              "${needs == null ? '' : "  s.dependency '$needs'${version == null ? '' : ", '$version'"}\n"}"
              "  s.platform = :osx, '10.15'\nend\n",
        );
        write(
          '$name/macos/Classes/$className.h',
          '@import FlutterMacOS;\n'
              '@interface $className : NSObject <FlutterPlugin>\n@end\n',
        );
        write(
          '$name/macos/Classes/$className.m',
          '#import "$className.h"\n@implementation $className\n'
              '+ (void)registerWithRegistrar:(id<FlutterPluginRegistrar>)registrar {}\n'
              '@end\n',
        );
      }

      plugin('plugin_a', 'PluginA');
      plugin('plugin_b', 'PluginB', needs: 'plugin_a');
      void configure(List<String> plugins) {
        write(
          'app/pubspec.yaml',
          'name: app\ndependencies:\n${[for (final name in plugins) '  $name:\n'].join()}',
        );
        write(
          'app/.dart_tool/package_config.json',
          jsonEncode({
            'configVersion': 2,
            'packages': [
              {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
              for (final name in plugins)
                {'name': name, 'rootUri': '../../$name', 'packageUri': 'lib/'},
            ],
          }),
        );
      }

      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);
      final data = p.join(temp.path, 'data');
      var log = '';
      Future<Map<String, Object?>> install() async {
        final result = await Process.run(
          p.join(runnerDir, 'tool', 'raccoon-device'),
          ['install', bundle.path, 'app'],
          environment: {
            'RACCOON_RUNNER': binary!,
            if (sdk != null) 'FLUTTER_ROOT': sdk,
            'XDG_DATA_HOME': data,
            'RACCOON_PLUGIN_CACHE': p.join(temp.path, 'cache'),
            'RACCOON_NO_PREBUILT': '1',
          },
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        log = '${result.stderr}';
        final manifest = File(
          p.join(data, 'raccoon', 'apps', 'app', 'plugins', 'manifest.json'),
        );
        expect(manifest.existsSync(), isTrue, reason: '${result.stderr}');
        return jsonDecode(manifest.readAsStringSync()) as Map<String, Object?>;
      }

      List<String> loaded(Map<String, Object?> manifest) => [
        for (final entry in manifest['plugins'] as List)
          '${(entry as Map)['name']}',
      ];
      try {
        configure(['plugin_a']);
        expect(loaded(await install()), ['plugin_a']);
        // #184: nothing reuses a cached plugin's intermediates.
        final build = p.join(
          data,
          'raccoon',
          'apps',
          'app',
          'plugins',
          'build',
        );
        for (final root in ['obj', 'out']) {
          expect(
            Directory(p.join(build, root, 'plugin_a')).existsSync(),
            isFalse,
          );
        }
        configure(['plugin_a', 'plugin_b']);
        final second = await install();
        expect(second['status'], isEmpty);
        expect(loaded(second), ['plugin_a', 'plugin_b']);

        // #121: a path plugin's Dart code is not its native build; shared
        // native sources outside its platform folder are.
        write('plugin_a/lib/plugin_a.dart', '// changed\n');
        await install();
        expect(log, contains('from the cache: plugin_a'));
        write('plugin_a/src/extra.c', 'int extra(void) { return 1; }\n');
        final rebuilt = await install();
        expect(log, contains('built: plugin_a'));
        expect(loaded(rebuilt), ['plugin_a', 'plugin_b']);
        // #274: plugin_b built against the new plugin_a is an entry of its
        // own, beside the one an app still on the old plugin_a uses.
        expect(
          Directory(p.join(temp.path, 'cache'))
              .listSync()
              .map((entry) => p.basename(entry.path))
              .where(
                (name) =>
                    name.startsWith('plugin_b-') && !name.contains('.partial'),
              ),
          hasLength(2),
        );

        // #183: a pod that wants a version no source has drops its plugin
        // only; CocoaPods lists both, the one it names still builds.
        plugin('plugin_d', 'PluginD');
        plugin('plugin_e', 'PluginE', needs: 'plugin_d', version: '9.9.9');
        configure(['plugin_d', 'plugin_e']);
        final missing = await install();
        expect(loaded(missing), ['plugin_d']);
        expect(
          [
            for (final entry in missing['status'] as List)
              '${(entry as Map)['name']}',
          ],
          ['plugin_e'],
        );

        // #187: a Swift package that does not build leaves the plugin to
        // its podspec.
        plugin('plugin_g', 'PluginG');
        write('plugin_g/macos/plugin_g/Package.swift', 'not a manifest\n');
        configure(['plugin_g']);
        final fallback = await install();
        expect(log, contains('CocoaPods instead'));
        expect(loaded(fallback), ['plugin_g']);
        expect(
          '${((fallback['plugins'] as List).single as Map)['library']}',
          endsWith('plugin_g.framework/plugin_g'),
        );

        // #191: one Swift package that does not resolve (its product named
        // other than Flutter names it) leaves the others to build.
        void swiftPlugin(
          String name,
          String className, {
          String? product,
          String? shared,
          String? needs,
        }) {
          write(
            '$name/pubspec.yaml',
            'name: $name\nversion: 1.0.0\n'
                // Four spaces, as some pubspecs have them (#203).
                '${needs == null ? '' : 'dependencies:\n    $needs:\n'}'
                'flutter:\n  plugin:\n    platforms:\n'
                '      macos:\n        pluginClass: $className\n',
          );
          write(
            '$name/macos/$name/Package.swift',
            '// swift-tools-version: 5.9\nimport PackageDescription\n'
                'let package = Package(name: "$name", platforms: [.macOS("10.15")],\n'
                '  products: [.library(name: "${product ?? name.replaceAll('_', '-')}", targets: ["$name"])],\n'
                '  dependencies: [.package(name: "FlutterFramework", path: "../FlutterFramework")'
                '${shared == null ? '' : ', .package(url: "file://${p.join(temp.path, 'shared')}", exact: "$shared")'}],\n'
                '  targets: [.target(name: "$name", dependencies: [\n'
                '    .product(name: "FlutterFramework", package: "FlutterFramework")'
                '${shared == null ? '' : ', .product(name: "Shared", package: "shared")'}])])\n',
          );
          write(
            '$name/macos/$name/Sources/$name/include/$className.h',
            '#import <FlutterMacOS/FlutterMacOS.h>\n'
                '@interface $className : NSObject <FlutterPlugin>\n@end\n',
          );
          write(
            '$name/macos/$name/Sources/$name/$className.m',
            '#import "$className.h"\n@implementation $className\n'
                '+ (void)registerWithRegistrar:(id<FlutterPluginRegistrar>)registrar {}\n'
                '@end\n',
          );
        }

        swiftPlugin('plugin_h', 'PluginH');
        swiftPlugin('plugin_i', 'PluginI', product: 'PluginI');
        configure(['plugin_h', 'plugin_i']);
        final one = await install();
        expect(loaded(one), ['plugin_h']);
        expect(
          '${((one['plugins'] as List).single as Map)['library']}',
          endsWith('RaccoonPlugins.framework/RaccoonPlugins'),
        );
        expect(
          [
            for (final entry in one['status'] as List)
              '${(entry as Map)['name']}',
          ],
          ['plugin_i'],
        );
        // Left out at once next time, the others from the cache.
        final next = await install();
        expect(log, contains('1 from the cache: plugin_h'));
        expect(
          '${((next['status'] as List).single as Map)['detail']}',
          contains('kept from'),
        );

        // #192: two that want versions of a third no one version gives. The
        // side with fewer plugins tied to it goes, though the error names
        // the other first.
        Future<void> git(List<String> args) async {
          final result = await Process.run('git', [
            '-c',
            'user.name=raccoon',
            '-c',
            'user.email=raccoon@example.com',
            '-c',
            'commit.gpgsign=false',
            '-c',
            'tag.gpgsign=false',
            ...args,
          ], workingDirectory: p.join(temp.path, 'shared'));
          expect(result.exitCode, 0, reason: '${result.stderr}');
        }

        write(
          'shared/Package.swift',
          '// swift-tools-version: 5.9\nimport PackageDescription\n'
              'let package = Package(name: "Shared",\n'
              '  products: [.library(name: "Shared", targets: ["Shared"])],\n'
              '  targets: [.target(name: "Shared")])\n',
        );
        write('shared/Sources/Shared/Shared.swift', 'public let shared = 1\n');
        await git(['init', '-q']);
        await git(['add', '.']);
        await git(['commit', '-qm', 'one']);
        await git(['tag', '1.0.0']);
        write('shared/Sources/Shared/Shared.swift', 'public let shared = 2\n');
        await git(['commit', '-qam', 'two']);
        await git(['tag', '2.0.0']);
        swiftPlugin('plugin_j', 'PluginJ', shared: '1.0.0');
        swiftPlugin('plugin_k', 'PluginK', shared: '2.0.0');
        swiftPlugin('plugin_l', 'PluginL', needs: 'plugin_j');
        configure(['plugin_j', 'plugin_k', 'plugin_l']);
        final conflict = await install();
        expect(loaded(conflict), ['plugin_j', 'plugin_l']);
        expect(
          [
            for (final entry in conflict['status'] as List)
              '${(entry as Map)['name']}',
          ],
          ['plugin_k'],
        );
        // #203: with the other side gone, plugin_k builds again rather than
        // staying left out for a day.
        configure(['plugin_k']);
        final alone = await install();
        expect(loaded(alone), ['plugin_k']);
        expect(alone['status'], isEmpty);
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((binary != null && sdk != null, Platform.isMacOS)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'CocoaPods plugins are macOS',
      _ => false,
    },
    // Pods, Swift packages, their culprits and a version conflict, each
    // built cold: past 5 minutes on an Intel CI runner.
    timeout: const Timeout(Duration(minutes: 10)),
  );
  // #122: one failed download turned prebuilts off for good, and an
  // interrupted unpack left half entries that counted as cached.
  test(
    'on macOS a prebuilt download that fails is asked again next time',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_prebuilt');
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      // A plugin whose pod doesn't compile: never cached, so every install
      // asks for a prebuilt first.
      write(
        'plugin_np/macos/plugin_np.podspec',
        "Pod::Spec.new do |s|\n  s.name = 'plugin_np'\n  s.version = '1.0.0'\n"
            "  s.summary = 'plugin_np'\n  s.homepage = 'https://example.com'\n"
            "  s.license = { :type => 'BSD' }\n  s.author = 'Raccoon'\n"
            "  s.source = { :path => '.' }\n  s.source_files = 'Classes/**/*'\n"
            "  s.dependency 'FlutterMacOS'\n  s.platform = :osx, '10.15'\nend\n",
      );
      write('plugin_np/macos/Classes/PluginNp.m', 'this does not compile\n');
      write(
        'plugin_np/pubspec.yaml',
        'name: plugin_np\nversion: 1.0.0\nflutter:\n  plugin:\n    platforms:\n'
            '      macos:\n        pluginClass: PluginNp\n',
      );
      write('app/pubspec.yaml', 'name: app\ndependencies:\n  plugin_np:\n');
      write(
        'app/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            {
              'name': 'plugin_np',
              'rootUri': '../../plugin_np',
              'packageUri': 'lib/',
            },
          ],
        }),
      );
      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);
      final cache = Directory(p.join(temp.path, 'cache'));
      Future<void> install(String prebuilt) async {
        await Process.run(
          p.join(runnerDir, 'tool', 'raccoon-device'),
          ['install', bundle.path, 'app'],
          environment: {
            'RACCOON_RUNNER': binary!,
            if (sdk != null) 'FLUTTER_ROOT': sdk,
            'XDG_DATA_HOME': p.join(temp.path, 'data'),
            'RACCOON_PLUGIN_CACHE': cache.path,
            'RACCOON_PREBUILT_PLUGINS': prebuilt,
          },
        );
      }

      Iterable<String> names() =>
          cache.existsSync()
              ? cache.listSync().map((e) => p.basename(e.path))
              : const [];
      try {
        // No archive there, as with no network: nothing is remembered.
        await install(Uri.file(p.join(temp.path, 'missing.tar.gz')).toString());
        expect(names().where((n) => n.endsWith('.done')), isEmpty);
        expect(names().where((n) => n.startsWith('.prebuilt-')), isEmpty);

        // A server that hangs up: not remembered either.
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((socket) => socket.destroy());
        try {
          await install('http://127.0.0.1:${server.port}/prebuilt.tar.gz');
        } finally {
          await server.close();
        }
        expect(names().where((n) => n.endsWith('.done')), isEmpty);
        expect(names().where((n) => n.startsWith('.prebuilt-')), isEmpty);

        // An archive there: its entries move in, and the fetch is noted.
        final source = Directory(p.join(temp.path, 'archive', 'some-entry'))
          ..createSync(recursive: true);
        File(p.join(source.path, 'lib.dylib')).writeAsStringSync('x');
        final archive = p.join(temp.path, 'prebuilt.tar.gz');
        final tar = await Process.run('tar', [
          '-czf',
          archive,
          '-C',
          p.join(temp.path, 'archive'),
          'some-entry',
        ]);
        expect(tar.exitCode, 0, reason: '${tar.stderr}');
        await install(Uri.file(archive).toString());
        expect(names(), contains('some-entry'));
        expect(names().where((n) => n.endsWith('.done')), hasLength(1));
        expect(names().where((n) => n.startsWith('.prebuilt-')), isEmpty);
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((binary != null && sdk != null, Platform.isMacOS)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'the macOS plugin builder',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'on macOS a pod asking for an older macOS builds for this one',
    () async {
      // plugin_c asks for macOS 10.13 and uses UTType, which is macOS 11:
      // built at 10.13 it doesn't compile, as Flutter's own build never
      // does it (#83).
      final temp = Directory.systemTemp.createTempSync('raccoon_pods');
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      write(
        'plugin_c/pubspec.yaml',
        'name: plugin_c\nversion: 1.0.0\nflutter:\n  plugin:\n    platforms:\n'
            '      macos:\n        pluginClass: PluginC\n',
      );
      write(
        'plugin_c/macos/plugin_c.podspec',
        "Pod::Spec.new do |s|\n  s.name = 'plugin_c'\n  s.version = '1.0.0'\n"
            "  s.summary = 'plugin_c'\n  s.homepage = 'https://example.com'\n"
            "  s.license = { :type => 'BSD' }\n  s.author = 'Raccoon'\n"
            "  s.source = { :path => '.' }\n  s.source_files = 'Classes/**/*'\n"
            "  s.dependency 'FlutterMacOS'\n  s.swift_version = '5.0'\n"
            "  s.platform = :osx, '10.13'\nend\n",
      );
      write(
        'plugin_c/macos/Classes/PluginC.swift',
        'import FlutterMacOS\nimport UniformTypeIdentifiers\n\n'
            'public class PluginC: NSObject, FlutterPlugin {\n'
            '  public static func register(with registrar: FlutterPluginRegistrar) {\n'
            '    _ = UTType.png\n  }\n}\n',
      );
      write('app/pubspec.yaml', 'name: app\ndependencies:\n  plugin_c:\n');
      write(
        'app/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            {
              'name': 'plugin_c',
              'rootUri': '../../plugin_c',
              'packageUri': 'lib/',
            },
          ],
        }),
      );
      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);
      final data = p.join(temp.path, 'data');
      try {
        final result = await Process.run(
          p.join(runnerDir, 'tool', 'raccoon-device'),
          ['install', bundle.path, 'app'],
          environment: {
            'RACCOON_RUNNER': binary!,
            if (sdk != null) 'FLUTTER_ROOT': sdk,
            'XDG_DATA_HOME': data,
            'RACCOON_PLUGIN_CACHE': p.join(temp.path, 'cache'),
            'RACCOON_NO_PREBUILT': '1',
          },
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final manifest =
            jsonDecode(
                  File(
                    p.join(
                      data,
                      'raccoon',
                      'apps',
                      'app',
                      'plugins',
                      'manifest.json',
                    ),
                  ).readAsStringSync(),
                )
                as Map;
        expect(manifest['status'], isEmpty);
        expect(
          [
            for (final entry in manifest['plugins'] as List)
              '${(entry as Map)['name']}',
          ],
          ['plugin_c'],
        );
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((binary != null && sdk != null, Platform.isMacOS)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'CocoaPods plugins are macOS',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
  test(
    'a plugin that fails to build is kept failed until it changes',
    () async {
      // #136: building it again costs pod install and xcodebuild, or
      // CMake, on every install. Kept by its key and the toolchain, for a day; retried at
      // once with RACCOON_RETRY_PLUGINS=1, or when its sources change.
      final temp = Directory.systemTemp.createTempSync('raccoon_pods');
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      write(
        'plugin_f/pubspec.yaml',
        'name: plugin_f\nversion: 1.0.0\nflutter:\n  plugin:\n    platforms:\n'
            '      linux:\n        pluginClass: PluginF\n'
            '      macos:\n        pluginClass: PluginF\n',
      );
      write(
        'plugin_f/macos/plugin_f.podspec',
        "Pod::Spec.new do |s|\n  s.name = 'plugin_f'\n  s.version = '1.0.0'\n"
            "  s.summary = 'plugin_f'\n  s.homepage = 'https://example.com'\n"
            "  s.license = { :type => 'BSD' }\n  s.author = 'Raccoon'\n"
            "  s.source = { :path => '.' }\n  s.source_files = 'Classes/**/*'\n"
            "  s.dependency 'FlutterMacOS'\n  s.platform = :osx, '10.15'\nend\n",
      );
      write(
        'plugin_f/macos/Classes/PluginF.h',
        '@import FlutterMacOS;\n@interface PluginF : NSObject <FlutterPlugin>\n@end\n',
      );
      void source({
        required bool compiles,
        String broken = 'not code;',
      }) => write(
        'plugin_f/macos/Classes/PluginF.m',
        '#import "PluginF.h"\n@implementation PluginF\n'
            '+ (void)registerWithRegistrar:(id<FlutterPluginRegistrar>)registrar {\n'
            '  ${compiles ? '' : broken}\n}\n@end\n',
      );
      write(
        'plugin_f/linux/CMakeLists.txt',
        'cmake_minimum_required(VERSION 3.14)\n'
            'add_library(plugin_f_plugin SHARED plugin_f.cc)\n',
      );
      void linuxSource({required bool compiles, String broken = 'not code;'}) =>
          write(
            'plugin_f/linux/plugin_f.cc',
            compiles ? 'int plugin_f_value() { return 1; }\n' : '$broken\n',
          );
      source(compiles: false);
      linuxSource(compiles: false);
      write('app/pubspec.yaml', 'name: app\ndependencies:\n  plugin_f:\n');
      write(
        'app/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            {
              'name': 'plugin_f',
              'rootUri': '../../plugin_f',
              'packageUri': 'lib/',
            },
          ],
        }),
      );
      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);
      final data = p.join(temp.path, 'data');
      // The detail the helper gave plugin_f, null once it built.
      Future<String?> install({bool retry = false}) async {
        final result = await Process.run(
          p.join(runnerDir, 'tool', 'raccoon-device'),
          ['install', bundle.path, 'app'],
          environment: {
            'RACCOON_RUNNER': binary!,
            if (sdk != null) 'FLUTTER_ROOT': sdk,
            'XDG_DATA_HOME': data,
            'RACCOON_PLUGIN_CACHE': p.join(temp.path, 'cache'),
            'RACCOON_NO_PREBUILT': '1',
            if (retry) 'RACCOON_RETRY_PLUGINS': '1',
          },
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final manifest =
            jsonDecode(
                  File(
                    p.join(
                      data,
                      'raccoon',
                      'apps',
                      'app',
                      'plugins',
                      'manifest.json',
                    ),
                  ).readAsStringSync(),
                )
                as Map;
        for (final entry in manifest['status'] as List) {
          final status = entry as Map;
          if (status['name'] == 'plugin_f') return status['detail'] as String;
        }
        return null;
      }

      try {
        final first = await install();
        expect(first, startsWith('did not build'));
        expect(first, isNot(contains('kept')));
        final kept = await install();
        expect(kept, contains('kept from'));
        // Its log is kept beside the failure: the install's is written over.
        final log = RegExp(r'see (\S+\.log)').firstMatch(kept ?? '')?.group(1);
        expect(log, isNotNull);
        expect(File(log ?? '').readAsStringSync(), contains('not code'));
        expect(await install(retry: true), isNot(contains('kept')));
        source(compiles: true);
        linuxSource(compiles: true);
        expect(await install(), isNull);
        // A build the machine stopped (a full disk) is not the plugin's
        // fault, and is not kept.
        const full = '#error No space left on device';
        source(compiles: false, broken: full);
        linuxSource(compiles: false, broken: full);
        expect(await install(), startsWith('did not build'));
        expect(await install(), isNot(contains('kept')));
        // Nor is one that failed for want of a network (#255).
        const offline = '#error Could not resolve host: cdn.cocoapods.org';
        source(compiles: false, broken: offline);
        linuxSource(compiles: false, broken: offline);
        expect(await install(), startsWith('did not build'));
        expect(await install(), isNot(contains('kept')));
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((binary != null && sdk != null, Platform.isWindows)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, true) => 'Windows builds plugins in its own helper',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
  test(
    'on Linux a plugin gets its target platform and its bundled libraries; '
    'one that made nothing is kept, a configure failure is not',
    () async {
      // #246: three FFI plugins. plugin_b bundles a versioned library and
      // checks FLUTTER_TARGET_PLATFORM; plugin_n builds nothing (jni without
      // a JDK); plugin_c stops CMake configuring (a missing -dev package).
      final temp = Directory.systemTemp.createTempSync('raccoon_linux');
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      void plugin(String name, String cmake) {
        write(
          '$name/pubspec.yaml',
          'name: $name\nversion: 1.0.0\nflutter:\n  plugin:\n    platforms:\n'
              '      linux:\n        ffiPlugin: true\n',
        );
        write('$name/linux/CMakeLists.txt', cmake);
      }

      plugin(
        'plugin_b',
        'cmake_minimum_required(VERSION 3.14)\n'
            'if(NOT FLUTTER_TARGET_PLATFORM MATCHES "^linux-(x64|arm64)\$")\n'
            '  message(FATAL_ERROR "no target platform")\n'
            'endif()\n'
            'add_library(plugin_b SHARED plugin_b.cc)\n'
            'set(plugin_b_bundled_libraries "\$<TARGET_FILE:plugin_b>" '
            '"\${CMAKE_CURRENT_SOURCE_DIR}/libs/libextra.so.1" '
            '"\${CMAKE_CURRENT_SOURCE_DIR}/libs/model.bin" PARENT_SCOPE)\n',
      );
      write(
        'plugin_b/linux/plugin_b.cc',
        'int plugin_b_value() { return 1; }\n',
      );
      write('plugin_b/linux/libs/libextra.so.1', 'not really a library\n');
      write('plugin_b/linux/libs/model.bin', 'data the plugin finds\n');
      plugin('plugin_n', 'cmake_minimum_required(VERSION 3.14)\n');
      plugin(
        'plugin_c',
        'cmake_minimum_required(VERSION 3.14)\n'
            'message(FATAL_ERROR "a -dev package is missing")\n',
      );
      write(
        'app/pubspec.yaml',
        'name: app\ndependencies:\n  plugin_b:\n  plugin_n:\n  plugin_c:\n',
      );
      write(
        'app/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            for (final name in ['plugin_b', 'plugin_n', 'plugin_c'])
              {'name': name, 'rootUri': '../../$name', 'packageUri': 'lib/'},
          ],
        }),
      );
      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);
      final data = p.join(temp.path, 'data');
      final plugins = p.join(data, 'raccoon', 'apps', 'app', 'plugins');
      // Each plugin's state and detail.
      Future<Map<String, String>> install() async {
        final result = await Process.run(
          p.join(runnerDir, 'tool', 'raccoon-device'),
          ['install', bundle.path, 'app'],
          environment: {
            'RACCOON_RUNNER': binary!,
            if (sdk != null) 'FLUTTER_ROOT': sdk,
            'XDG_DATA_HOME': data,
            'RACCOON_PLUGIN_CACHE': p.join(temp.path, 'cache'),
            'RACCOON_NO_PREBUILT': '1',
          },
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final manifest =
            jsonDecode(
                  File(p.join(plugins, 'manifest.json')).readAsStringSync(),
                )
                as Map;
        return {
          for (final entry in (manifest['status'] as List).cast<Map>())
            '${entry['name']}': '${entry['state']}: ${entry['detail']}',
        };
      }

      try {
        final first = await install();
        expect(first.containsKey('plugin_b'), isFalse, reason: '$first');
        expect(
          Directory(
            p.join(plugins, 'lib'),
          ).listSync().map((file) => p.basename(file.path)),
          containsAll(['libplugin_b.so', 'libextra.so.1', 'model.bin']),
        );
        // Its build tree goes once it is cached.
        expect(
          Directory(p.join(plugins, 'build', 'plugin_b')).existsSync(),
          isFalse,
        );
        expect(first['plugin_n'], 'built_nothing: built and made no library');
        expect(first['plugin_c'], startsWith('failed: did not build'));
        final second = await install();
        expect(second['plugin_n'], startsWith('built_nothing: '));
        expect(second['plugin_n'], contains('kept from'));
        expect(second['plugin_c'], isNot(contains('kept')));
        // The cache keeps the versioned library and the data too.
        expect(
          Directory(
            p.join(plugins, 'lib'),
          ).listSync().map((file) => p.basename(file.path)),
          containsAll(['libextra.so.1', 'model.bin']),
        );
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((binary != null && sdk != null, Platform.isLinux)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'the Linux half of the helper',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
  test(
    'on Windows a plugin is cached whole, and rebuilt when its sources change',
    () async {
      // #141: the echo plugin, copied under a folder named hosted (which is
      // not pub's cache), built by the Windows helper on its own.
      final temp = Directory.systemTemp.createTempSync('raccoon_windows');
      final root = p.join(temp.path, 'hosted', 'raccoon_echo');
      final source = p.join(runnerDir, 'example', 'plugins', 'echo');
      for (final file in Directory(source).listSync(recursive: true)) {
        final relative = p.relative(file.path, from: source);
        if (file is! File || relative.startsWith('.')) continue;
        file.copySync(
          (File(p.join(root, relative))
            ..parent.createSync(recursive: true)).path,
        );
      }
      final config =
          File(p.join(temp.path, 'app', '.dart_tool', 'p.json'))
            ..createSync(recursive: true)
            ..writeAsStringSync(
              jsonEncode({
                'configVersion': 2,
                'packages': [
                  {
                    'name': 'raccoon_echo',
                    'rootUri': Uri.directory(root).toString(),
                  },
                ],
              }),
            );
      final cache = p.join(temp.path, 'cache');
      final out = p.join(temp.path, 'out');
      Future<String> build() async {
        final result = await Process.run(
          p.join(sdk!, 'bin', 'cache', 'dart-sdk', 'bin', 'dart.exe'),
          [
            p.join(runnerDir, 'tool', 'plugins_windows.dart'),
            config.path,
            out,
            '',
            cache,
            '0.0.0-test',
            p.join(sdk, 'bin', 'cache', 'artifacts', 'engine', 'windows-x64'),
          ],
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        return '${result.stderr}';
      }

      // A build that failed says why in its log, and CMake's own.
      String log() {
        final build = p.join(out, 'build', 'raccoon_echo');
        return [
          for (final path in [
            p.join(build, 'build.log'),
            p.join(build, 'out', 'CMakeFiles', 'CMakeConfigureLog.yaml'),
          ])
            if (File(path).existsSync()) File(path).readAsStringSync(),
        ].join('\n');
      }

      try {
        expect(await build(), contains('1 built: raccoon_echo'), reason: log());
        final manifest =
            jsonDecode(File(p.join(out, 'manifest.json')).readAsStringSync())
                as Map;
        expect(
          '${(manifest['plugins'] as List).single['library']}',
          endsWith('raccoon_echo_plugin.dll'),
        );
        // One entry, renamed into place; nothing staged left behind.
        final entries = Directory(cache)
            .listSync()
            .whereType<Directory>()
            .map((entry) => p.basename(entry.path))
            .where((name) => name != 'failed');
        expect(entries, [startsWith('raccoon_echo-path-')]);
        expect(await build(), contains('1 from the cache: raccoon_echo'));
        // A source beside windows/, as an FFI plugin's src/.
        File(p.join(root, 'src', 'shared.c'))
          ..createSync(recursive: true)
          ..writeAsStringSync('int shared(void) { return 1; }\n');
        expect(await build(), contains('1 built: raccoon_echo'), reason: log());
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((sdk != null, Platform.isWindows)) {
      (false, _) => 'needs a Flutter SDK on PATH',
      (_, false) => 'the Windows plugin helper',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );

  test(
    'on macOS a ready-made framework in a plugin\'s pod lands beside it',
    () async {
      // plugin_d's pod brings Ready.xcframework, a dynamic framework the
      // plugin links, as Agora's pods bring AgoraRtcWrapper. CocoaPods
      // leaves it under XCFrameworkIntermediates; without it beside the
      // plugin, the plugin never loads (#84).
      final temp = Directory.systemTemp.createTempSync('raccoon_pods');
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      final ready = p.join(temp.path, 'ready', 'Ready.framework');
      write('ready/ready.c', 'int ready_value(void) { return 42; }\n');
      write(
        'ready/Ready.framework/Versions/A/Headers/Ready.h',
        'int ready_value(void);\n',
      );
      write(
        'ready/Ready.framework/Versions/A/Resources/Info.plist',
        '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>'
            '<key>CFBundleExecutable</key><string>Ready</string>'
            '<key>CFBundleIdentifier</key><string>dev.raccoon.ready</string>'
            '<key>CFBundlePackageType</key><string>FMWK</string>'
            '</dict></plist>\n',
      );
      Future<void> run(String executable, List<String> arguments) async {
        final result = await Process.run(executable, arguments);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }

      await run('xcrun', [
        'clang',
        '-dynamiclib',
        '-arch',
        'arm64',
        '-arch',
        'x86_64',
        '-install_name',
        '@rpath/Ready.framework/Versions/A/Ready',
        '-o',
        p.join(ready, 'Versions', 'A', 'Ready'),
        p.join(temp.path, 'ready', 'ready.c'),
      ]);
      for (final (link, target) in [
        ('Versions/Current', 'A'),
        ('Ready', 'Versions/Current/Ready'),
        ('Headers', 'Versions/Current/Headers'),
        ('Resources', 'Versions/Current/Resources'),
      ]) {
        Link(p.join(ready, link)).createSync(target);
      }
      await run('xcodebuild', [
        '-create-xcframework',
        '-framework',
        ready,
        '-output',
        p.join(temp.path, 'plugin_d', 'macos', 'Ready.xcframework'),
      ]);
      write(
        'plugin_d/pubspec.yaml',
        'name: plugin_d\nversion: 1.0.0\nflutter:\n  plugin:\n    platforms:\n'
            '      macos:\n        pluginClass: PluginD\n',
      );
      write(
        'plugin_d/macos/plugin_d.podspec',
        "Pod::Spec.new do |s|\n  s.name = 'plugin_d'\n  s.version = '1.0.0'\n"
            "  s.summary = 'plugin_d'\n  s.homepage = 'https://example.com'\n"
            "  s.license = { :type => 'BSD' }\n  s.author = 'Raccoon'\n"
            "  s.source = { :path => '.' }\n  s.source_files = 'Classes/**/*'\n"
            "  s.vendored_frameworks = 'Ready.xcframework'\n"
            "  s.pod_target_xcconfig = { 'OTHER_LDFLAGS' => '-framework Ready' }\n"
            "  s.dependency 'FlutterMacOS'\n  s.platform = :osx, '10.15'\nend\n",
      );
      write(
        'plugin_d/macos/Classes/PluginD.h',
        '@import FlutterMacOS;\n@interface PluginD : NSObject <FlutterPlugin>\n@end\n',
      );
      write(
        'plugin_d/macos/Classes/PluginD.m',
        '#import "PluginD.h"\n#import <Ready/Ready.h>\n@implementation PluginD\n'
            '+ (void)registerWithRegistrar:(id<FlutterPluginRegistrar>)registrar {\n'
            '  (void)ready_value();\n}\n@end\n',
      );
      write('app/pubspec.yaml', 'name: app\ndependencies:\n  plugin_d:\n');
      write(
        'app/.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            {
              'name': 'plugin_d',
              'rootUri': '../../plugin_d',
              'packageUri': 'lib/',
            },
          ],
        }),
      );
      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);
      final data = p.join(temp.path, 'data');
      try {
        final result = await Process.run(
          p.join(runnerDir, 'tool', 'raccoon-device'),
          ['install', bundle.path, 'app'],
          environment: {
            'RACCOON_RUNNER': binary!,
            if (sdk != null) 'FLUTTER_ROOT': sdk,
            'XDG_DATA_HOME': data,
            'RACCOON_PLUGIN_CACHE': p.join(temp.path, 'cache'),
            'RACCOON_NO_PREBUILT': '1',
          },
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final plugins = p.join(data, 'raccoon', 'apps', 'app', 'plugins');
        final manifest =
            jsonDecode(
                  File(p.join(plugins, 'manifest.json')).readAsStringSync(),
                )
                as Map;
        expect(manifest['status'], isEmpty);
        expect(
          Directory(
            p.join(plugins, 'frameworks'),
          ).listSync().map((entry) => p.basename(entry.path)),
          containsAll(['plugin_d.framework', 'Ready.framework']),
        );
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((binary != null && sdk != null, Platform.isMacOS)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'CocoaPods plugins are macOS',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
  // pub.dev's top-level platforms: list, as isar_community_flutter_libs
  // declares it: a hosts' key of each name, with nothing under it (#92).
  const topLevelPlatforms =
      'platforms:\n  android:\n  ios:\n  linux:\n  macos:\n  windows:\n';
  Future<Map<String, Object?>> installFake(
    Directory temp,
    Map<String, String> files,
    List<String> plugins,
  ) async {
    for (final MapEntry(:key, :value) in files.entries) {
      File(p.join(temp.path, key))
        ..createSync(recursive: true)
        ..writeAsStringSync(value);
    }
    File(p.join(temp.path, 'app', 'pubspec.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        'name: app\ndependencies:\n${[for (final name in plugins) '  $name:\n'].join()}',
      );
    File(p.join(temp.path, 'app', '.dart_tool', 'package_config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
            for (final name in plugins)
              {'name': name, 'rootUri': '../../$name', 'packageUri': 'lib/'},
          ],
        }),
      );
    final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
      ..createSync(recursive: true);
    final data = p.join(temp.path, 'data');
    final result = await Process.run(
      p.join(runnerDir, 'tool', 'raccoon-device'),
      ['install', bundle.path, 'app'],
      environment: {
        'RACCOON_RUNNER': binary ?? '',
        if (sdk != null) 'FLUTTER_ROOT': sdk,
        'XDG_DATA_HOME': data,
        'RACCOON_PLUGIN_CACHE': p.join(temp.path, 'cache'),
        'RACCOON_NO_PREBUILT': '1',
      },
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final manifest = File(
      p.join(data, 'raccoon', 'apps', 'app', 'plugins', 'manifest.json'),
    );
    expect(manifest.existsSync(), isTrue, reason: '${result.stderr}');
    return jsonDecode(manifest.readAsStringSync()) as Map<String, Object?>;
  }

  test(
    'a top-level platforms: list doesn\'t stand in for the plugin\'s own',
    () async {
      // Android only, by what flutter: plugin: says: no implementation for
      // this host, whatever the top-level list names.
      final temp = Directory.systemTemp.createTempSync('raccoon_platforms');
      addTearDown(() => temp.deleteSync(recursive: true));
      final manifest = await installFake(
        temp,
        {
          'mobile_only/pubspec.yaml':
              'name: mobile_only\nversion: 1.0.0\n$topLevelPlatforms'
              'flutter:\n  plugin:\n    platforms:\n      android:\n'
              '        package: dev.raccoon.mobile_only\n'
              '        pluginClass: MobileOnly\n',
        },
        ['mobile_only'],
      );
      expect(
        [
          for (final entry in manifest['status'] as List)
            ((entry as Map)['name'], entry['state']),
        ],
        [('mobile_only', 'no_host')],
      );
    },
    skip: switch ((binary != null && sdk != null, Platform.isWindows)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, true) => 'the helper runs in Git Bash on Windows',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'on macOS a plugin with a top-level platforms: list is built',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_platforms');
      addTearDown(() => temp.deleteSync(recursive: true));
      final manifest = await installFake(
        temp,
        {
          'plugin_e/pubspec.yaml':
              'name: plugin_e\nversion: 1.0.0\n$topLevelPlatforms'
              'flutter:\n  plugin:\n    platforms:\n      macos:\n'
              '        pluginClass: PluginE\n',
          'plugin_e/macos/plugin_e.podspec':
              "Pod::Spec.new do |s|\n  s.name = 'plugin_e'\n"
              "  s.version = '1.0.0'\n  s.summary = 'plugin_e'\n"
              "  s.homepage = 'https://example.com'\n"
              "  s.license = { :type => 'BSD' }\n  s.author = 'Raccoon'\n"
              "  s.source = { :path => '.' }\n"
              "  s.source_files = 'Classes/**/*'\n"
              "  s.dependency 'FlutterMacOS'\n"
              "  s.platform = :osx, '10.15'\nend\n",
          'plugin_e/macos/Classes/PluginE.h':
              '@import FlutterMacOS;\n'
              '@interface PluginE : NSObject <FlutterPlugin>\n@end\n',
          'plugin_e/macos/Classes/PluginE.m':
              '#import "PluginE.h"\n@implementation PluginE\n'
              '+ (void)registerWithRegistrar:(id<FlutterPluginRegistrar>)registrar {}\n'
              '@end\n',
        },
        ['plugin_e'],
      );
      expect(manifest['status'], isEmpty);
      expect(
        [
          for (final entry in manifest['plugins'] as List)
            '${(entry as Map)['name']}',
        ],
        ['plugin_e'],
      );
    },
    skip: switch ((binary != null && sdk != null, Platform.isMacOS)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'CocoaPods plugins are macOS',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
  test(
    'on macOS a pod\'s vendored framework and library land beside it',
    () async {
      // ffmpeg_kit_flutter_new vendors plain frameworks, isar's libs a
      // dylib: CocoaPods leaves both where they are, for an app's embed
      // step to copy (#93).
      final temp = Directory.systemTemp.createTempSync('raccoon_vendored');
      addTearDown(() => temp.deleteSync(recursive: true));
      final macos = p.join(temp.path, 'plugin_f', 'macos');
      final plain = p.join(macos, 'Plain.framework');
      Directory(p.join(plain, 'Versions', 'A')).createSync(recursive: true);
      File(
        p.join(temp.path, 'plain.c'),
      ).writeAsStringSync('int plain_value(void) { return 1; }\n');
      File(
        p.join(temp.path, 'ready.c'),
      ).writeAsStringSync('int ready_value(void) { return 2; }\n');
      Future<void> run(List<String> arguments) async {
        final result = await Process.run('xcrun', arguments);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }

      await run([
        'clang',
        '-dynamiclib',
        '-arch',
        'arm64',
        '-arch',
        'x86_64',
        '-install_name',
        '@rpath/Plain.framework/Versions/A/Plain',
        '-o',
        p.join(plain, 'Versions', 'A', 'Plain'),
        p.join(temp.path, 'plain.c'),
      ]);
      Link(p.join(plain, 'Versions', 'Current')).createSync('A');
      Link(p.join(plain, 'Plain')).createSync('Versions/Current/Plain');
      await run([
        'clang',
        '-dynamiclib',
        '-arch',
        'arm64',
        '-arch',
        'x86_64',
        '-install_name',
        '@rpath/libready.dylib',
        '-o',
        p.join(macos, 'libready.dylib'),
        p.join(temp.path, 'ready.c'),
      ]);

      final manifest = await installFake(
        temp,
        {
          'plugin_f/pubspec.yaml':
              'name: plugin_f\nversion: 1.0.0\nflutter:\n  plugin:\n'
              '    platforms:\n      macos:\n        pluginClass: PluginF\n',
          'plugin_f/macos/plugin_f.podspec':
              "Pod::Spec.new do |s|\n  s.name = 'plugin_f'\n"
              "  s.version = '1.0.0'\n  s.summary = 'plugin_f'\n"
              "  s.homepage = 'https://example.com'\n"
              "  s.license = { :type => 'BSD' }\n  s.author = 'Raccoon'\n"
              "  s.source = { :path => '.' }\n"
              "  s.source_files = 'Classes/**/*'\n"
              "  s.vendored_frameworks = 'Plain.framework'\n"
              "  s.vendored_libraries = 'libready.dylib'\n"
              "  s.pod_target_xcconfig = { 'OTHER_LDFLAGS' => "
              "'-framework Plain -lready' }\n"
              "  s.dependency 'FlutterMacOS'\n"
              "  s.platform = :osx, '10.15'\nend\n",
          'plugin_f/macos/Classes/PluginF.h':
              '@import FlutterMacOS;\n'
              '@interface PluginF : NSObject <FlutterPlugin>\n@end\n',
          'plugin_f/macos/Classes/PluginF.m':
              '#import "PluginF.h"\nint plain_value(void);\n'
              'int ready_value(void);\n@implementation PluginF\n'
              '+ (void)registerWithRegistrar:(id<FlutterPluginRegistrar>)registrar {\n'
              '  (void)(plain_value() + ready_value());\n}\n@end\n',
        },
        ['plugin_f'],
      );
      expect(manifest['status'], isEmpty);
      final frameworks = Directory(
        p.join(
          temp.path,
          'data',
          'raccoon',
          'apps',
          'app',
          'plugins',
          'frameworks',
        ),
      ).listSync().map((entry) => p.basename(entry.path));
      expect(
        frameworks,
        containsAll([
          'plugin_f.framework',
          'Plain.framework',
          'libready.dylib',
        ]),
      );
    },
    skip: switch ((binary != null && sdk != null, Platform.isMacOS)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, false) => 'CocoaPods plugins are macOS',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
  test(
    'a pub workspace member gets its own plugins, not the other members\'',
    () async {
      // A member has no package config of its own; the workspace root's
      // names every member's packages. Each member here depends on a plugin
      // with no desktop implementation, which the helper reports without
      // building anything: the report should name the app's, not the
      // other member's.
      final temp = Directory.systemTemp.createTempSync('raccoon_workspace');
      void write(String path, String text) =>
          File(p.join(temp.path, path))
            ..createSync(recursive: true)
            ..writeAsStringSync(text);
      String androidOnly(String name) =>
          'name: $name\n'
          'flutter:\n'
          '  plugin:\n'
          '    platforms:\n'
          '      android:\n'
          '        package: dev.raccoon.$name\n'
          '        pluginClass: Plugin\n';
      write(
        'pubspec.yaml',
        'name: _workspace\nworkspace:\n  - app\n  - other\n',
      );
      write(
        'app/pubspec.yaml',
        'name: app\nresolution: workspace\ndependencies:\n  app_plugin:\n',
      );
      write(
        'other/pubspec.yaml',
        'name: other\nresolution: workspace\ndependencies:\n  other_plugin:\n',
      );
      write('app_plugin/pubspec.yaml', androidOnly('app_plugin'));
      write('other_plugin/pubspec.yaml', androidOnly('other_plugin'));
      write(
        '.dart_tool/package_config.json',
        jsonEncode({
          'configVersion': 2,
          'packages': [
            for (final name in ['app', 'other', 'app_plugin', 'other_plugin'])
              {'name': name, 'rootUri': '../$name', 'packageUri': 'lib/'},
          ],
        }),
      );
      write(
        '.dart_tool/package_graph.json',
        jsonEncode({
          'configVersion': 1,
          'roots': ['app', 'other'],
          'packages': [
            {
              'name': 'app',
              'dependencies': ['app_plugin'],
            },
            {
              'name': 'other',
              'dependencies': ['other_plugin'],
            },
            {'name': 'app_plugin', 'dependencies': <String>[]},
            {'name': 'other_plugin', 'dependencies': <String>[]},
          ],
        }),
      );
      final bundle = Directory(p.join(temp.path, 'app', 'build', 'assets'))
        ..createSync(recursive: true);
      final data = p.join(temp.path, 'data');
      try {
        final install = await Process.run(
          p.join(runnerDir, 'tool', 'raccoon-device'),
          ['install', bundle.path, 'app'],
          environment: {
            'RACCOON_RUNNER': binary!,
            if (sdk != null) 'FLUTTER_ROOT': sdk,
            'XDG_DATA_HOME': data,
          },
        );
        expect(install.exitCode, 0, reason: '${install.stderr}');
        final manifest = File(
          p.join(data, 'raccoon', 'apps', 'app', 'plugins', 'manifest.json'),
        );
        expect(manifest.existsSync(), isTrue, reason: '${install.stderr}');
        final status = [
          for (final entry
              in (jsonDecode(manifest.readAsStringSync()) as Map)['status']
                  as List)
            '${(entry as Map)['name']}',
        ];
        expect(status, ['app_plugin']);
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((binary != null && sdk != null, Platform.isWindows)) {
      (false, _) => 'build the runner first, with a Flutter SDK on PATH',
      (_, true) => 'the helper runs in Git Bash on Windows',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    "answers the app's clipboard request through the client",
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      final calls = <String>[];
      client.registerChannel('flutter/platform', (data) async {
        final call = jsonDecode(utf8.decode(data)) as Map;
        calls.add(call['method'] as String);
        return switch (call['method']) {
          'Clipboard.getData' => _jsonReply({'text': 'raccoon'}),
          _ => null,
        };
      });
      try {
        await client.frames.first.timeout(const Duration(seconds: 15));
        for (final (phase, buttons) in [
          (PointerPhase.POINTER_PHASE_DOWN, 1),
          (PointerPhase.POINTER_PHASE_UP, 0),
        ]) {
          client.sendPointer(
            PointerEvent(
              phase: phase,
              x: 400,
              y: 300,
              buttons: Int64(buttons),
              device: PointerDevice.POINTER_DEVICE_MOUSE,
              pointerId: 1,
            ),
          );
        }
        await client.frames
            .firstWhere((f) => _pixel(f, 400, 300) == _purple)
            .timeout(const Duration(seconds: 10));
        expect(calls, contains('Clipboard.getData'));
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'frames stay right when the view shrinks after a large frame',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.frames.first.timeout(const Duration(seconds: 15));
        for (final (w, h, ratio) in [
          (1640, 2360, 2.0),
          (395, 870, 1.0),
          (780, 1688, 2.0),
          (395, 870, 1.0),
        ]) {
          client.resize(w, h, ratio);
          final frame = await client.frames
              .firstWhere((f) => f.width == w && f.height == h)
              .timeout(const Duration(seconds: 10));
          await Future<void>.delayed(const Duration(milliseconds: 300));
          final latest = client.latestFrame ?? frame;
          expect(latest.width, w);
          expect(latest.pixels.length, latest.rowBytes * latest.height);
          // Inside the box but above its label: where a glyph lands differs
          // between rasterizers by a pixel.
          expect(
            _pixel(
              latest,
              latest.width ~/ 2,
              latest.height ~/ 2 - (45 * ratio).round(),
            ),
            _red,
          );
          expect(_pixel(latest, 3, 3), _blue);
        }
        // Frames after the resizes keep coming through the latest set's
        // buffers: the runner takes their releases, named by that set's
        // generation (#135). Four taps, four frames, more than the set
        // holds without them.
        final before = client.sharedFrames;
        var box = _red;
        for (var tap = 0; tap < 4; tap++) {
          for (final (phase, buttons) in [
            (PointerPhase.POINTER_PHASE_DOWN, 1),
            (PointerPhase.POINTER_PHASE_UP, 0),
          ]) {
            client.sendPointer(
              PointerEvent(
                phase: phase,
                x: 197,
                y: 435,
                buttons: Int64(buttons),
                device: PointerDevice.POINTER_DEVICE_MOUSE,
                pointerId: 1,
              ),
            );
          }
          box = switch (box) {
            _red => _green,
            _ => _red,
          };
          final want = box;
          await client.frames
              .firstWhere((f) => f.width == 395 && _pixel(f, 197, 390) == want)
              .timeout(const Duration(seconds: 10));
        }
        if (!Platform.isWindows) {
          expect(client.sharedFrames - before, greaterThanOrEqualTo(4));
        }
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  // #117: Metal aborted on a side over 16,384 pixels. A frame too large is
  // scaled down to fit, its pixel ratio with it, and the app goes on.
  test(
    'a resize past the GPU\'s limit is scaled down, not fatal',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.frames.first.timeout(const Duration(seconds: 15));
        client.resize(16000, 400, 1);
        // 8192 / 16000 of each side: 8192 by 205.
        final scaled = await client.frames
            .firstWhere((f) => f.width == 8192)
            .timeout(const Duration(seconds: 15));
        expect(scaled.height, 205);
        expect(_pixel(scaled, 3, 3), _blue);
        // The host's pointer stays in the size it asked for: a tap on the
        // box, at the middle of 16000x400, lands on it (#130).
        for (final (phase, buttons) in [
          (PointerPhase.POINTER_PHASE_DOWN, 1),
          (PointerPhase.POINTER_PHASE_UP, 0),
        ]) {
          client.sendPointer(
            PointerEvent(
              phase: phase,
              x: 8000,
              y: 200,
              buttons: Int64(buttons),
              device: PointerDevice.POINTER_DEVICE_MOUSE,
              pointerId: 1,
            ),
          );
        }
        // Checked left of the box's centre, clear of its label: at this
        // pixel ratio a glyph can cover the centre, as on Linux's fonts.
        await client.frames
            .firstWhere(
              (f) => f.width == 8192 && _pixel(f, 4048, 102) == _green,
            )
            .timeout(const Duration(seconds: 10));
        client.resize(395, 870, 1);
        await client.frames
            .firstWhere((f) => f.width == 395 && f.height == 870)
            .timeout(const Duration(seconds: 10));
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  // example/channels calls desktop_window, window_manager, window_size and
  // shared_preferences_foundation at startup and shows a green box only when
  // every answer was right.
  final viewsAssets = p.join(
    runnerDir,
    'example',
    'views',
    'build',
    'flutter_assets',
  );
  test(
    'taps as a finger reach the app, each press a pointer of its own',
    () async {
      // #207: a view sends the mouse as a finger: down, up, then gone, a
      // new pointer every press. example/views' box turns white on a tap,
      // and red on the next.
      final temp = Directory.systemTemp.createTempSync('raccoon_touch');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: viewsAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          width: 390,
          height: 300,
          views: true,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        await client.frames.first.timeout(const Duration(seconds: 15));
        Future<void> tap(int pointer, ({int r, int g, int b}) colour) async {
          for (final (phase, buttons) in [
            (PointerPhase.POINTER_PHASE_DOWN, 1),
            (PointerPhase.POINTER_PHASE_UP, 0),
            (PointerPhase.POINTER_PHASE_REMOVE, 0),
          ]) {
            client.sendPointer(
              PointerEvent(
                phase: phase,
                x: 195,
                y: 150,
                buttons: Int64(buttons),
                device: PointerDevice.POINTER_DEVICE_TOUCH,
                pointerId: pointer,
              ),
            );
          }
          await client.frames
              .firstWhere((f) => _pixel(f, 195, 150) == colour)
              .timeout(const Duration(seconds: 10));
        }

        await tap(1, _white);
        await tap(2, _red);
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(viewsAssets).existsSync()
            ? false
            : 'build the runner and example/views first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a runner whose views socket cannot listen says it takes no views',
    () async {
      // #251: a folder where the views socket goes, so it cannot bind.
      final temp = Directory.systemTemp.createTempSync('raccoon_views');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      Directory(endpoint.views.path).createSync();
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: viewsAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          width: 390,
          height: 300,
          views: true,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        expect(client.takesViews, isFalse);
        // The app still draws for its first client.
        final frame = await client.frames.first.timeout(
          const Duration(seconds: 15),
        );
        expect((frame.width, frame.height), (390, 300));
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(viewsAssets).existsSync()
            ? false
            : 'build the runner and example/views first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'one run shows the app in a view per client, each its size and its taps',
    () async {
      // #182: example/views draws its root in every view, coloured by the
      // view's id (0 blue, 1 green, 2 orange), a box in the middle that a
      // tap turns from red to white.
      final temp = Directory.systemTemp.createTempSync('raccoon_views');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: viewsAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          width: 390,
          height: 300,
          views: true,
        ),
      );
      final first = await RunnerClient.connect(endpoint);
      final others = <RunnerClient>[];
      try {
        await first.hello.timeout(const Duration(seconds: 10));
        expect(first.takesViews, isTrue);
        expect(first.viewId, 0);
        final own = await first.frames.first.timeout(
          const Duration(seconds: 15),
        );
        expect((own.width, own.height), (390, 300));
        expect(_pixel(own, 5, 5), _blue);

        final second = await RunnerClient.connect(endpoint.views);
        others.add(second);
        await second.hello.timeout(const Duration(seconds: 10));
        expect(second.viewId, 1);
        second.resize(300, 200, 2);
        final frame = await second.frames
            .firstWhere((f) => f.width == 300)
            .timeout(const Duration(seconds: 15));
        expect(frame.height, 200);
        expect(_pixel(frame, 5, 5), _green);
        expect(_pixel(frame, 150, 100), _red);

        for (final (phase, buttons) in [
          (PointerPhase.POINTER_PHASE_DOWN, 1),
          (PointerPhase.POINTER_PHASE_UP, 0),
        ]) {
          second.sendPointer(
            PointerEvent(
              phase: phase,
              x: 150,
              y: 100,
              buttons: Int64(buttons),
              device: PointerDevice.POINTER_DEVICE_MOUSE,
              pointerId: 1,
            ),
          );
        }
        await second.frames
            .firstWhere((f) => _pixel(f, 150, 100) == _white)
            .timeout(const Duration(seconds: 10));
        // Each view has its own instance: the first's box stays red.
        expect(_pixel(first.latestFrame!, 195, 150), _red);

        // A view goes with its client; the next client has a new one.
        await second.close();
        final third = await RunnerClient.connect(endpoint.views);
        others.add(third);
        await third.hello.timeout(const Duration(seconds: 10));
        expect(third.viewId, 2);
        third.resize(200, 100, 1);
        final last = await third.frames
            .firstWhere((f) => f.width == 200)
            .timeout(const Duration(seconds: 15));
        expect(_pixel(last, 5, 5), _orange);
      } finally {
        for (final other in others) {
          await other.close();
        }
        first.shutdown();
        await first.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(viewsAssets).existsSync()
            ? false
            : 'build the runner and example/views first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'a view takes GPU buffers of its own, served on a GPU socket of its own',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_views');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: viewsAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          views: true,
        ),
      );
      final first = await RunnerClient.connect(endpoint, gpuBuffers: true);
      final view = await RunnerClient.connect(endpoint.views, gpuBuffers: true);
      try {
        await view.hello.timeout(const Duration(seconds: 10));
        // A frame in a GPU buffer is not replayed: listened for first.
        final gpuFrame = view.frames.firstWhere((f) => f.inGpuBuffer);
        gpuFrame.ignore();
        view.resize(320, 240, 2);
        final GpuBuffers set;
        try {
          set = await view.gpuBufferSets.first.timeout(
            const Duration(seconds: 5),
          );
        } on TimeoutException {
          printOnFailure('no GPU buffers offered: ${view.latestGpuBuffers}');
          return;
        }
        expect((set.width, set.height), (320, 240));
        expect(set.socket, p.join(temp.path, 'runner.v1.gpu'));
        expect(File(set.socket).existsSync() || Platform.isWindows, isTrue);
        final frame = await gpuFrame.timeout(const Duration(seconds: 10));
        expect(frame.gpuGeneration, set.generation);
        view.releaseGpuBuffer(frame.gpuGeneration, frame.bufferIndex);

        // The first view's ring is its own, at its own size.
        final own = await first.gpuBufferSets.first.timeout(
          const Duration(seconds: 10),
        );
        expect((own.width, own.height), (800, 600));
        expect(own.socket, p.join(temp.path, 'runner.gpu'));

        // A new size is a new ring.
        view.resize(400, 300, 2);
        final grown = await view.gpuBufferSets
            .firstWhere((s) => s.width == 400)
            .timeout(const Duration(seconds: 10));
        expect(grown.generation, greaterThan(set.generation));
      } finally {
        await view.close();
        first.shutdown();
        await first.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(viewsAssets).existsSync()
            ? false
            : 'build the runner and example/views first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'an app that only calls runApp draws in every view from the views entry',
    () async {
      // example/hello as it is, built through the generated entry point.
      final temp = Directory.systemTemp.createTempSync('raccoon_entry');
      final app = Directory(p.join(temp.path, 'hello'))..createSync();
      final hello = p.join(runnerDir, 'example', 'hello');
      for (final file in [
        'pubspec.yaml',
        'pubspec.lock',
        p.join('lib', 'main.dart'),
        p.join('.dart_tool', 'package_config.json'),
      ]) {
        final copy = File(p.join(app.path, file))
          ..parent.createSync(recursive: true);
        File(p.join(hello, file)).copySync(copy.path);
      }
      try {
        final entry = ViewsEntrypoint.write(app.path);
        expect(entry, p.join(app.path, ViewsEntrypoint.path));
        final target = switch (Platform.operatingSystem) {
          'macos' => 'darwin',
          'windows' => 'windows-x64',
          _ when Platform.version.contains('arm64') => 'linux-arm64',
          _ => 'linux-x64',
        };
        final build = await Process.run(
          p.join(sdk!, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter'),
          ['build', 'bundle', '-t', entry!, '--target-platform=$target'],
          workingDirectory: app.path,
          runInShell: Platform.isWindows,
        );
        expect(build.exitCode, 0, reason: '${build.stdout}${build.stderr}');
        final out = p.join(temp.path, 'frame.ppm');
        final render = await Process.run(binary!, [
          'render',
          '--engine-dir',
          engineDir!,
          '--assets',
          p.join(app.path, 'build', 'flutter_assets'),
          '--icu',
          icu!,
          '--view',
          '600x400@1',
          '--out',
          out,
        ]);
        expect(render.exitCode, 0, reason: '${render.stderr}');
        for (final (file, width) in [
          (out, 800),
          (p.join(temp.path, 'frame.view1.ppm'), 600),
        ]) {
          final bytes = File(file).readAsBytesSync();
          // P6, width, height, 255, then RGB from the first pixel.
          final header = String.fromCharCodes(
            bytes.take(32),
          ).split(RegExp(r'\s+'));
          expect(int.parse(header[1]), width);
          final start =
              '${header[0]}\n${header[1]} ${header[2]}\n${header[3]}\n'.length;
          expect((
            r: bytes[start],
            g: bytes[start + 1],
            b: bytes[start + 2],
          ), _blue);
        }
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready && sdk != null ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'the generated entry shows the app with the device\'s safe area and '
    'platform',
    () async {
      // #194: example/hello's packages, a main that prints what it is laid
      // out with each build.
      final temp = Directory.systemTemp.createTempSync('raccoon_device');
      final app = Directory(p.join(temp.path, 'hello'))..createSync();
      final hello = p.join(runnerDir, 'example', 'hello');
      for (final file in [
        'pubspec.yaml',
        'pubspec.lock',
        p.join('.dart_tool', 'package_config.json'),
      ]) {
        final copy = File(p.join(app.path, file))
          ..parent.createSync(recursive: true);
        File(p.join(hello, file)).copySync(copy.path);
      }
      File(p.join(app.path, 'lib', 'main.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

void main() => runApp(const Report());

class Report extends StatelessWidget {
  const Report({super.key});

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final viewPadding = MediaQuery.viewPaddingOf(context);
    print('DEVICE:\${defaultTargetPlatform.name};\${padding.top};'
        '\${padding.bottom};\${viewPadding.bottom}');
    return const SizedBox();
  }
}
''');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      RunnerProcess? runner;
      RunnerClient? client;
      try {
        final entry = RaccoonEntrypoint.write(app.path);
        expect(entry, p.join(app.path, RaccoonEntrypoint.path));
        final build = await Process.run(
          p.join(sdk!, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter'),
          ['build', 'bundle', '-t', entry!],
          workingDirectory: app.path,
          runInShell: Platform.isWindows,
        );
        expect(build.exitCode, 0, reason: '${build.stdout}${build.stderr}');
        runner = await RunnerProcess.start(
          RunnerLaunch(
            runnerBinary: binary!,
            engineDir: engineDir!,
            assets: p.join(app.path, 'build', 'flutter_assets'),
            icuData: icu!,
            endpoint: endpoint,
          ),
        );
        final output = <String>[];
        runner.stdout.listen(output.add);
        client = await RunnerClient.connect(endpoint);
        final device =
            DeviceChannel()
              ..fallback = const DeviceProfile(
                padding: (top: 47, right: 0, bottom: 34, left: 0),
                platform: 'iOS',
              );
        device.attach(client);
        await client.hello.timeout(const Duration(seconds: 10));
        Future<void> laidOut(String line) async {
          final deadline = DateTime.now().add(const Duration(seconds: 15));
          while (!output.contains(line) && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(output, contains(line));
        }

        client.resize(1170, 2532, 3);
        await laidOut('DEVICE:iOS;47.0;34.0;34.0');
        // A keyboard 300 high covers the home indicator: no padding left
        // below, the view's padding the same.
        client.setViewInsets(bottom: 900);
        await laidOut('DEVICE:iOS;47.0;0.0;34.0');
      } finally {
        client?.shutdown();
        await client?.close();
        if (runner != null) expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready && sdk != null ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 3)),
  );
  final channelsAssets = p.join(
    runnerDir,
    'example',
    'channels',
    'build',
    'flutter_assets',
  );
  test(
    'the runner answers the window and shared preferences channels itself',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: channelsAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      final forwarded = <String>[];
      for (final channel in [
        'desktop_window',
        'window_manager',
        'flutter/windowsize',
        'dev.flutter.pigeon.shared_preferences_foundation.LegacyUserDefaultsApi.getAll',
        'dev.flutter.pigeon.shared_preferences_foundation.UserDefaultsApi.getValue',
      ]) {
        client.registerChannel(channel, (data) async {
          forwarded.add(channel);
          return null;
        });
      }
      try {
        final frame = await client.frames.first.timeout(
          const Duration(seconds: 15),
        );
        expect(_pixel(frame, 5, 5), _blue);
        expect(
          _pixel(frame, 400, 300),
          _green,
          reason: 'a channel call failed; the app logs which',
        );
        expect(forwarded, isEmpty);
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(channelsAssets).existsSync()
            ? false
            : 'build the runner and example/channels first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  // example/camera lists the cameras, takes a picture and streams in each
  // format through the camera plugin, checking the test pattern's colours.
  final cameraAssets = p.join(
    runnerDir,
    'example',
    'camera',
    'build',
    'flutter_assets',
  );
  // raccoon_test_video writes a third of a second of H.264, red and green
  // over blue and yellow, the same in every frame; with --probe it says what
  // a video holds.
  final testVideo = switch (binary) {
    final binary? => p.join(p.dirname(binary), 'raccoon_test_video.exe'),
    null => '',
  };
  test(
    'the runner answers the camera plugin from a test pattern',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: cameraAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final lines = <String>[];
      final done = Completer<void>();
      var framesSeen = 0;
      var framesAtIdle = 0;
      var framesAfterIdle = 0;
      var framesAtShown = 0;
      var framesAfterShown = 0;
      runner.stdout.listen((line) {
        final at = line.indexOf('CAMERA:');
        if (at < 0) return;
        final said = line.substring(at + 'CAMERA:'.length);
        if (said == 'idle') framesAtIdle = framesSeen;
        if (said == 'idle end') framesAfterIdle = framesSeen;
        if (said == 'shown') framesAtShown = framesSeen;
        if (said == 'shown end') framesAfterShown = framesSeen;
        lines.add(said);
        if ((said == 'done' || said.startsWith('error')) && !done.isCompleted) {
          done.complete();
        }
      });
      final client = await RunnerClient.connect(endpoint);
      final forwarded = <String>[];
      client.registerChannel('plugins.flutter.io/camera', (data) async {
        forwarded.add('plugins.flutter.io/camera');
        return null;
      });
      // The preview fills the view while the first camera streams: the test
      // pattern's first bar is white, its last blue.
      var previewed = false;
      final frames = client.frames.listen((frame) {
        framesSeen++;
        final y = frame.height ~/ 4;
        if (_pixel(frame, frame.width ~/ 14, y) == (r: 255, g: 255, b: 255) &&
            _pixel(frame, frame.width * 13 ~/ 14, y) == (r: 0, g: 0, b: 255)) {
          previewed = true;
        }
      });
      try {
        await done.future.timeout(const Duration(seconds: 30));
        await frames.cancel();
        if (runner.renderer == 'gl' || runner.renderer == 'metal') {
          expect(previewed, isTrue, reason: 'no frame showed the preview');
          // #114: two seconds of a camera nobody shows are a few frames,
          // not sixty.
          final idle = framesAfterIdle - framesAtIdle;
          expect(idle, lessThan(20));
          // Shown again, it runs at its frame rate: two seconds are about
          // 60 frames, the probe's about 8. Measured against the same
          // machine's idle two seconds, twice as many and at least 10: a
          // loaded CI runner drew 12 where 20 was asked for.
          expect(
            framesAfterShown - framesAtShown,
            greaterThan(idle * 2 < 10 ? 10 : idle * 2),
          );
        }
        expect(lines, contains('cameras back,front'));
        expect(lines, contains('initialized 352x288'));
        final picture = _pictureLine.firstMatch(
          lines.firstWhere((l) => l.startsWith('picture')),
        );
        expect(picture?[1], 'bars ok');
        final file = File(picture?[4] ?? '');
        expect(file.readAsBytesSync().take(2), [0xFF, 0xD8]);
        file.deleteSync();
        // Video range: white is 235, blue 41.
        final yuv = lines.firstWhere((l) => l.startsWith('stream yuv420'));
        expect(yuv, contains('planes=3 352x288 y=235/41'));
        final fps = double.parse(yuv.split('fps=').last);
        expect(fps, inInclusiveRange(20, 40));
        expect(
          lines,
          contains(
            startsWith('stream bgra8888 planes=1 raw=1111970369 bars ok'),
          ),
        );
        expect(
          lines,
          contains(startsWith('stream jpeg planes=1 raw=256 bars ok')),
        );
        // 600 ms recorded, 400 paused, 400 more: a second of video on
        // Windows, the pattern in it; refused elsewhere.
        final video = lines.firstWhere((l) => l.startsWith('video '));
        if (Platform.isWindows) {
          final path = video.substring('video '.length);
          final probe = await Process.run(testVideo, ['--probe', path]);
          final held = RegExp(
            r'frames=(\d+) size=(\S+) duration_ms=(\d+) left=(\S+) right=(\S+)',
          ).firstMatch('${probe.stdout}');
          expect(held, isNotNull, reason: '${probe.stdout}${probe.stderr}');
          expect(int.parse(held?[1] ?? '0'), inInclusiveRange(25, 36));
          expect(held?[2], '352x288');
          expect(int.parse(held?[3] ?? '0'), inInclusiveRange(850, 1250));
          final left = (held?[4] ?? '').split(',').map(int.parse);
          final right = (held?[5] ?? '').split(',').map(int.parse).toList();
          expect(left.every((c) => c > 230), isTrue, reason: 'left $left');
          expect(
            right[0] < 30 && right[1] < 30 && right[2] > 220,
            isTrue,
            reason: 'right $right',
          );
          File(path).deleteSync();
        } else {
          expect(video, 'video refused videoRecordingFailed');
        }
        expect(lines.last, 'done');
        expect(forwarded, isEmpty);
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(cameraAssets).existsSync()
            ? false
            : 'build the runner and example/camera first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'the camera shows a picture given as its source',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      // Red on the left half, green on the right: whatever the camera's
      // aspect crops, the bars' places fall in one half each.
      final source = File(p.join(temp.path, 'source.png'))..writeAsBytesSync(
        _png(160, 120, (x, y) => x < 80 ? [220, 20, 30] : [20, 200, 40]),
      );
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: cameraAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          cameraSource: source.path,
        ),
      );
      final lines = <String>[];
      final done = Completer<void>();
      runner.stdout.listen((line) {
        final at = line.indexOf('CAMERA:');
        if (at < 0) return;
        final said = line.substring(at + 'CAMERA:'.length);
        lines.add(said);
        if ((said == 'done' || said.startsWith('error')) && !done.isCompleted) {
          done.complete();
        }
      });
      final client = await RunnerClient.connect(endpoint);
      // Each channel within 12 of the source's, as JPEG keeps it.
      bool near(String seen, List<int> want) {
        final got = seen.split(',').map(int.parse).toList();
        return [
          for (var i = 0; i < 3; i++) (got[i] - want[i]).abs() <= 12,
        ].every((close) => close);
      }

      try {
        await done.future.timeout(const Duration(seconds: 30));
        final picture = _pictureLine.firstMatch(
          lines.firstWhere((l) => l.startsWith('picture')),
        );
        expect(picture, isNotNull, reason: lines.join('\n'));
        expect(
          near(picture?[2] ?? '0,0,0', [220, 20, 30]),
          isTrue,
          reason: 'left ${picture?[2]}',
        );
        expect(
          near(picture?[3] ?? '0,0,0', [20, 200, 40]),
          isTrue,
          reason: 'right ${picture?[3]}',
        );
        File(picture?[4] ?? '').deleteSync();
        final bgra = RegExp(
          r'left=(\S+) right=(\S+)',
        ).firstMatch(lines.firstWhere((l) => l.startsWith('stream bgra8888')));
        expect(bgra?[1], '220,20,30');
        expect(bgra?[2], '20,200,40');
        expect(lines.last, 'done');
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(cameraAssets).existsSync()
            ? false
            : 'build the runner and example/camera first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  /// Runs example/camera with [source] as the camera's source; its CAMERA:
  /// lines.
  Future<List<String>> runCamera(Directory temp, String source) async {
    final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
    final runner = await RunnerProcess.start(
      RunnerLaunch(
        runnerBinary: binary ?? '',
        engineDir: engineDir ?? '',
        assets: cameraAssets,
        icuData: icu ?? '',
        endpoint: endpoint,
        cameraSource: source,
      ),
    );
    final lines = <String>[];
    final done = Completer<void>();
    runner.stdout.listen((line) {
      final at = line.indexOf('CAMERA:');
      if (at < 0) return;
      final step = line.substring(at + 'CAMERA:'.length);
      lines.add(step);
      if ((step == 'done' || step.startsWith('error')) && !done.isCompleted) {
        done.complete();
      }
    });
    final client = await RunnerClient.connect(endpoint);
    try {
      await done.future.timeout(const Duration(seconds: 30));
    } finally {
      client.shutdown();
      await client.close();
      expect(await _exitCode(runner), 0);
    }
    final picture = _pictureLine.firstMatch(
      lines.firstWhere((l) => l.startsWith('picture'), orElse: () => ''),
    );
    if (picture?[4] case final path?) File(path).deleteSync();
    return lines;
  }

  test(
    'the camera plays a video given as its source, in a loop',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      addTearDown(() => temp.deleteSync(recursive: true));
      final video = p.join(temp.path, 'source.mp4');
      final made = await Process.run(testVideo, [video]);
      expect(made.exitCode, 0, reason: '${made.stderr}');
      final lines = await runCamera(temp, video);
      // Each channel within 16 of the video's, as H.264 and then JPEG keep
      // them; the top half is red and green, so neither half is flipped.
      void near(String what, String? seen, List<int> want) {
        final got = (seen ?? '0,0,0').split(',').map(int.parse).toList();
        final close = [
          for (var i = 0; i < 3; i++) (got[i] - want[i]).abs() <= 16,
        ].every((each) => each);
        expect(close, isTrue, reason: '$what $seen, not $want');
      }

      final colours = RegExp(r'left=(\S+) right=(\S+)');
      final picture = colours.firstMatch(
        lines.firstWhere((l) => l.startsWith('picture')),
      );
      near('picture left', picture?[1], [220, 20, 30]);
      near('picture right', picture?[2], [20, 200, 40]);
      // The streams run past the video's end, so their later frames come
      // after it started again.
      final yuv = lines.firstWhere((l) => l.startsWith('stream yuv420'));
      expect(double.parse(yuv.split('fps=').last), inInclusiveRange(20, 40));
      for (final format in ['bgra8888', 'jpeg']) {
        final seen = colours.firstMatch(
          lines.firstWhere((l) => l.startsWith('stream $format')),
        );
        near('$format left', seen?[1], [220, 20, 30]);
        near('$format right', seen?[2], [20, 200, 40]);
      }
      expect(lines.last, 'done');
    },
    skip:
        !Platform.isWindows
            ? 'videos play on Windows only for now'
            : ready &&
                Directory(cameraAssets).existsSync() &&
                File(testVideo).existsSync()
            ? false
            : 'build the runner, raccoon_test_video and example/camera first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'elsewhere a video source is refused and the pattern stays',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      addTearDown(() => temp.deleteSync(recursive: true));
      final video = File(p.join(temp.path, 'source.mp4'))
        ..writeAsBytesSync([0, 0, 0, 0]);
      final lines = await runCamera(temp, video.path);
      // The pattern's bars: the runner said why (before it listened) and
      // kept to its pattern.
      expect(
        lines,
        contains(startsWith('stream bgra8888 planes=1 raw=1111970369 bars ok')),
      );
    },
    skip:
        Platform.isWindows
            ? 'Windows plays videos'
            : ready && Directory(cameraAssets).existsSync()
            ? false
            : 'build the runner and example/camera first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'keys reach the framework and typed characters reach a text field',
    () async {
      // example/text prints KEY:<event> for every key the framework
      // dispatches and TEXT:<value> for every change of its field.
      final textAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'text',
        'build',
        'flutter_assets',
      );
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: textAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      runner.stderr.listen(output.add);
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.frames.first.timeout(const Duration(seconds: 15));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        Future<void> key(int logical, int physical, String character) async {
          for (final kind in [KeyKind.KEY_KIND_DOWN, KeyKind.KEY_KIND_UP]) {
            client.sendKey(
              KeyEvent(
                kind: kind,
                physical: Int64(physical),
                logical: Int64(logical),
                character: kind == KeyKind.KEY_KIND_DOWN ? character : '',
                timestampMicros: Int64(DateTime.now().microsecondsSinceEpoch),
              ),
            );
            await Future<void>.delayed(const Duration(milliseconds: 60));
          }
        }

        await key(0x68, 0x0007000b, 'h');
        await key(0x69, 0x0007000c, 'i');
        // Backspace is the framework's: its shortcut deletes, not the runner.
        await key(0x100000008, 0x0007002a, '');
        // Typed only once the field shows the deletion: the framework sends
        // the edited text after its frame, which a slow host may not have
        // drawn 60 ms on, and a key before it edits the text before it.
        final deleted = DateTime.now().add(const Duration(seconds: 10));
        while (output
                    .where((line) => line.trimRight().endsWith('TEXT:h'))
                    .length <
                2 &&
            DateTime.now().isBefore(deleted)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await key(0x79, 0x0007001c, 'y');
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!output.any((line) => line.contains('TEXT:hy')) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final text =
            output
                .where((line) => line.contains('TEXT:'))
                .map((line) => line.substring(line.indexOf('TEXT:')))
                .toList();
        expect(text, ['TEXT:h', 'TEXT:hi', 'TEXT:h', 'TEXT:hy']);
        expect(
          output.where((line) => line.contains('KEY:KeyDownEvent')).length,
          4,
        );
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready &&
                Directory(
                  p.join(
                    p.dirname(p.dirname(p.dirname(assets))),
                    'text',
                    'build',
                    'flutter_assets',
                  ),
                ).existsSync()
            ? false
            : 'build the runner and the text example first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'the deprecated RawKeyboard tells keys apart and keeps a modifier held '
    'on either side',
    () async {
      // example/text prints RAW:<type>:<physical>:<pressed>:<shift>:<control>
      // for every RawKeyboard event; physical keys are HID usages in hex.
      final textAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'text',
        'build',
        'flutter_assets',
      );
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: textAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      runner.stderr.listen(output.add);
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.frames.first.timeout(const Duration(seconds: 15));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        Future<void> send(
          KeyKind kind,
          int logical,
          int physical, [
          String character = '',
        ]) async {
          client.sendKey(
            KeyEvent(
              kind: kind,
              physical: Int64(physical),
              logical: Int64(logical),
              character: character,
              timestampMicros: Int64(DateTime.now().microsecondsSinceEpoch),
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 60));
        }

        const down = KeyKind.KEY_KIND_DOWN;
        const up = KeyKind.KEY_KIND_UP;
        // A down, B down, A up: B is still held.
        await send(down, 0x61, 0x00070004, 'a');
        await send(down, 0x62, 0x00070005, 'b');
        await send(up, 0x61, 0x00070004);
        await send(up, 0x62, 0x00070005);
        // Both Shifts down, the left one up: Shift is still held.
        await send(down, 0x200000102, 0x000700e1);
        await send(down, 0x200000103, 0x000700e5);
        await send(up, 0x200000102, 0x000700e1);
        await send(down, 0x63, 0x00070006, 'C');
        await send(up, 0x63, 0x00070006);
        await send(up, 0x200000103, 0x000700e5);
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        bool done() =>
            output.any((line) => line.contains('RAW:RawKeyUpEvent:700e5:'));
        while (!done() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final raw =
            output
                .where((line) => line.contains('RAW:'))
                .map((line) => line.substring(line.indexOf('RAW:')))
                .toList();
        printOnFailure(raw.join('\n'));
        String event(String type, String physical) =>
            raw.firstWhere((line) => line.startsWith('RAW:$type:$physical:'));
        final aUp = event('RawKeyUpEvent', '70004').split(':')[3].split(',');
        expect(aUp, contains('70005'));
        expect(aUp, isNot(contains('70004')));
        final cDown = event('RawKeyDownEvent', '70006').split(':');
        expect(cDown[3].split(','), contains('70006'));
        expect(cDown.sublist(4), ['true', 'false']);
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready &&
                Directory(
                  p.join(
                    p.dirname(p.dirname(p.dirname(assets))),
                    'text',
                    'build',
                    'flutter_assets',
                  ),
                ).existsSync()
            ? false
            : 'build the runner and the text example first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'on a Mac, editing keys reach the field as AppKit selectors',
    () async {
      // A Mac app's framework leaves Option, Cmd and arrow keys in a text
      // field to the platform and waits for performSelectors.
      final textAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'text',
        'build',
        'flutter_assets',
      );
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: textAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      runner.stderr.listen(output.add);
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.frames.first.timeout(const Duration(seconds: 15));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        Future<void> send(KeyKind kind, int logical, int physical, String c) {
          client.sendKey(
            KeyEvent(
              kind: kind,
              physical: Int64(physical),
              logical: Int64(logical),
              character: c,
              timestampMicros: Int64(DateTime.now().microsecondsSinceEpoch),
            ),
          );
          return Future<void>.delayed(const Duration(milliseconds: 60));
        }

        Future<void> key(int logical, int physical, [String c = '']) async {
          await send(KeyKind.KEY_KIND_DOWN, logical, physical, c);
          await send(KeyKind.KEY_KIND_UP, logical, physical, '');
        }

        // A key with a modifier held: (logical, physical) pairs.
        Future<void> held((int, int) modifier, (int, int) pressed) async {
          await send(KeyKind.KEY_KIND_DOWN, modifier.$1, modifier.$2, '');
          await key(pressed.$1, pressed.$2);
          await send(KeyKind.KEY_KIND_UP, modifier.$1, modifier.$2, '');
        }

        await key(0x61, 0x00070004, 'a');
        await key(0x62, 0x00070005, 'b');
        await key(0x20, 0x0007002c, ' ');
        await key(0x63, 0x00070006, 'c');
        await key(0x64, 0x00070007, 'd');
        // Option+Backspace deletes the word, Cmd+Left goes to the line's
        // start.
        await held((0x200000104, 0x000700e2), (0x100000008, 0x0007002a));
        await held((0x200000106, 0x000700e3), (0x100000302, 0x00070050));
        await key(0x78, 0x0007001b, 'x');
        // Ctrl+H deletes back, AppKit's Emacs key that Flutter leaves to it.
        await held((0x200000100, 0x000700e0), (0x68, 0x0007000b));
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (output.where((line) => line.contains('TEXT:')).length < 8 &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final text =
            output
                .where((line) => line.contains('TEXT:'))
                .map((line) => line.substring(line.indexOf('TEXT:')))
                .toList();
        expect(text, [
          'TEXT:a',
          'TEXT:ab',
          'TEXT:ab ',
          'TEXT:ab c',
          'TEXT:ab cd',
          'TEXT:ab ',
          'TEXT:xab ',
          'TEXT:ab ',
        ]);
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch (ready &&
        Directory(
          p.join(
            p.dirname(p.dirname(p.dirname(assets))),
            'text',
            'build',
            'flutter_assets',
          ),
        ).existsSync()) {
      false => 'build the runner and the text example first',
      true when !Platform.isMacOS => 'AppKit selectors are a Mac app\'s',
      true => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'Alt picks a character on a Mac (Option) only, not elsewhere',
    () async {
      // Option types what the key gives on a Mac; elsewhere Alt with a
      // letter is a shortcut nobody took, and GTK and Windows type nothing.
      final textAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'text',
        'build',
        'flutter_assets',
      );
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: textAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      runner.stderr.listen(output.add);
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.frames.first.timeout(const Duration(seconds: 15));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        Future<void> send(KeyKind kind, int logical, int physical, String c) {
          client.sendKey(
            KeyEvent(
              kind: kind,
              physical: Int64(physical),
              logical: Int64(logical),
              character: c,
              timestampMicros: Int64(DateTime.now().microsecondsSinceEpoch),
            ),
          );
          return Future<void>.delayed(const Duration(milliseconds: 60));
        }

        Future<void> key(int logical, int physical, [String c = '']) async {
          await send(KeyKind.KEY_KIND_DOWN, logical, physical, c);
          await send(KeyKind.KEY_KIND_UP, logical, physical, '');
        }

        await key(0x61, 0x00070004, 'a');
        // Alt+F, the character as the host reports it: Option gives ƒ.
        await send(KeyKind.KEY_KIND_DOWN, 0x200000104, 0x000700e2, '');
        await key(0x66, 0x00070009, Platform.isMacOS ? 'ƒ' : 'f');
        await send(KeyKind.KEY_KIND_UP, 0x200000104, 0x000700e2, '');
        await key(0x62, 0x00070005, 'b');
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        final last = Platform.isMacOS ? 'TEXT:aƒb' : 'TEXT:ab';
        while (!output.any((line) => line.contains(last)) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final text =
            output
                .where((line) => line.contains('TEXT:'))
                .map((line) => line.substring(line.indexOf('TEXT:')))
                .toList();
        expect(
          text,
          Platform.isMacOS
              ? ['TEXT:a', 'TEXT:aƒ', 'TEXT:aƒb']
              : ['TEXT:a', 'TEXT:ab'],
        );
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch (ready &&
        Directory(
          p.join(
            p.dirname(p.dirname(p.dirname(assets))),
            'text',
            'build',
            'flutter_assets',
          ),
        ).existsSync()) {
      false => 'build the runner and the text example first',
      true => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a socket it cannot listen on ends the runner cleanly',
    () async {
      // By then the engine runs: it goes down before the runner returns,
      // rather than under its threads.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final socket = p.join(temp.path, '${'s' * 200}.sock');
      final runner = await Process.start(binary ?? '', [
        'serve',
        '--engine-dir',
        engineDir ?? '',
        '--assets',
        assets,
        '--icu',
        icu ?? '',
        '--socket',
        socket,
      ]);
      final errors = <String>[];
      runner.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(errors.add);
      unawaited(runner.stdout.drain<void>());
      try {
        final code = await runner.exitCode.timeout(const Duration(seconds: 15));
        expect(code, 1, reason: errors.join('\n'));
        expect(errors.join('\n'), isNot(contains('stopped')));
      } finally {
        runner.kill();
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'a host that claims a run takes it from one that yields; nobody else does',
    () async {
      // raccoon#281.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      Future<Object?> outcome(RunnerClient client) async {
        try {
          await client.hello.timeout(const Duration(seconds: 10));
          return 'hello';
        } on Object catch (error) {
          return error;
        }
      }

      final holder = await RunnerClient.connect(endpoint, yields: true);
      RunnerClient? owner;
      try {
        expect(await outcome(holder), 'hello');
        await holder.frames.first.timeout(const Duration(seconds: 15));
        // Another that doesn't claim it: Busy, the holder stays.
        final other = await RunnerClient.connect(endpoint);
        expect(await outcome(other), isA<RunnerBusy>());
        await other.close();
        // One that connects and says nothing holds the waiting place for a
        // second at most.
        final silent = await Socket.connect(
          InternetAddress(endpoint.path, type: InternetAddressType.unix),
          0,
        );
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        // Its own host claims it: the holder goes, the owner has it.
        owner = await RunnerClient.connect(endpoint, claims: true);
        expect(await outcome(owner), 'hello');
        await holder.closed.timeout(const Duration(seconds: 5));
        await owner.frames.first.timeout(const Duration(seconds: 15));
        // A claim against a holder that doesn't yield: Busy, as before.
        final late = await RunnerClient.connect(endpoint, claims: true);
        expect(await outcome(late), isA<RunnerBusy>());
        await late.close();
        silent.destroy();
      } finally {
        await holder.close();
        final client = owner;
        if (client != null) {
          client.shutdown();
          await client.close();
        }
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'a second client is told who has the runner, then hung up on',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final first = await RunnerClient.connect(endpoint);
      try {
        await first.hello.timeout(const Duration(seconds: 10));
        // The runner says hello before it reads the client's; give it time
        // to learn the first client's pid.
        await first.frames.first.timeout(const Duration(seconds: 15));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        Object? failure;
        RunnerClient? second;
        try {
          second = await RunnerClient.connect(endpoint);
          await second.hello.timeout(const Duration(seconds: 5));
        } on Object catch (error) {
          failure = error;
        }
        expect(failure, isA<RunnerBusy>().having((b) => b.pid, 'pid', pid));
        await second?.closed.timeout(const Duration(seconds: 5));
        await second?.close();
      } finally {
        first.shutdown();
        await first.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );

  // #138: the runner kept the last client's pid after it left, and told a
  // newcomer that one held it.
  test(
    'a client that left is not named to a newcomer',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final address = InternetAddress(
        endpoint.path,
        type: InternetAddressType.unix,
      );
      Socket? quiet;
      try {
        final first = await RunnerClient.connect(endpoint);
        await first.frames.first.timeout(const Duration(seconds: 15));
        await first.close();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        // Holds the runner without a hello yet.
        quiet = await Socket.connect(address, 0);
        quiet.listen(null);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        Object? failure;
        RunnerClient? newcomer;
        try {
          newcomer = await RunnerClient.connect(endpoint);
          await newcomer.hello.timeout(const Duration(seconds: 5));
        } on Object catch (error) {
          failure = error;
        }
        expect(failure, isA<RunnerBusy>().having((b) => b.pid, 'pid', 0));
        await newcomer?.close();
      } finally {
        quiet?.destroy();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final last = await RunnerClient.connect(endpoint);
        await last.hello.timeout(const Duration(seconds: 5));
        last.shutdown();
        await last.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'a raw socket stands in for a client',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  // #145: a client whose set came short says hello again without shared
  // buffers; the runner sends it frames inline from then on.
  test(
    'a hello without shared buffers turns the runner to inline frames',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final socket = await RawSocket.connect(
        InternetAddress(endpoint.path, type: InternetAddressType.unix),
        0,
      );
      final unframer = MessageUnframer();
      final messages = StreamController<RunnerMessage>.broadcast();
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final message = socket.readMessage();
        if (message == null) return;
        for (final control in message.controlMessages) {
          for (final handle in control.extractHandles()) {
            handle.toFile().closeSync();
          }
        }
        for (final payload in unframer.add(message.data)) {
          messages.add(RunnerMessage.fromBuffer(payload));
        }
      });
      void send(ClientMessage message) =>
          socket.write(MessageFraming.frame(message.writeToBuffer()));
      try {
        final set = messages.stream.firstWhere((m) => m.hasSharedBuffers());
        send(
          ClientMessage(
            hello: ClientHello(protocolVersion: 1, pid: 1, sharedBuffers: true),
          ),
        );
        await set.timeout(const Duration(seconds: 15));

        final inline = messages.stream.firstWhere(
          (m) => m.hasFrame() && !m.frame.inSharedBuffer,
        );
        send(
          ClientMessage(
            hello: ClientHello(
              protocolVersion: 1,
              pid: 1,
              sharedBuffers: false,
            ),
          ),
        );
        final frame = (await inline.timeout(const Duration(seconds: 5))).frame;
        expect(frame.pixels, isNotEmpty);
        send(ClientMessage(shutdown: Shutdown()));
        expect(await _exitCode(runner), 0);
      } finally {
        await socket.close();
        await messages.close();
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'shared buffers are Unix sockets',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  // #153: a hello again without GPU buffers left the ring in use, and the
  // client got no frames at all.
  test(
    'a hello without GPU buffers turns the runner back to pixel frames',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final socket = await RawSocket.connect(
        InternetAddress(endpoint.path, type: InternetAddressType.unix),
        0,
      );
      final unframer = MessageUnframer();
      final messages = StreamController<RunnerMessage>.broadcast();
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        // No shared buffers asked for, so no descriptors come: a plain
        // read, which Windows has too.
        final data = socket.read();
        if (data == null) return;
        for (final payload in unframer.add(data)) {
          messages.add(RunnerMessage.fromBuffer(payload));
        }
      });
      void send(ClientMessage message) =>
          socket.write(MessageFraming.frame(message.writeToBuffer()));
      try {
        // The first frame may come inline, before the hello is read.
        final first = messages.stream
            .firstWhere((m) => m.hasFrame() && m.frame.inGpuBuffer)
            .then<RunnerMessage?>((m) => m)
            .timeout(const Duration(seconds: 15), onTimeout: () => null);
        send(
          ClientMessage(
            hello: ClientHello(protocolVersion: 1, pid: 1, gpuBuffers: true),
          ),
        );
        // Without a GPU (a CI machine) there is no ring to leave.
        if (await first == null) {
          send(ClientMessage(shutdown: Shutdown()));
          expect(await _exitCode(runner), 0);
          return;
        }

        final inline = messages.stream.firstWhere(
          (m) => m.hasFrame() && !m.frame.inGpuBuffer,
        );
        send(ClientMessage(hello: ClientHello(protocolVersion: 1, pid: 1)));
        final frame = (await inline.timeout(const Duration(seconds: 5))).frame;
        expect(frame.pixels, isNotEmpty);
        send(ClientMessage(shutdown: Shutdown()));
        expect(await _exitCode(runner), 0);
      } finally {
        await socket.close();
        await messages.close();
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'on Windows frames keep their pace with a temp path too long for a socket',
    () async {
      // #126: the event loop's wake is a pair of sockets named in the temp
      // directory; a path past a socket name's 108 bytes made none, and
      // the loop woke once a second. The loopback stands in.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final long = Directory(p.join(temp.path, 'x' * 60, 'y' * 60))
        ..createSync(recursive: true);
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final spinAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'spin',
        'build',
        'flutter_assets',
      );
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: spinAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
        startProcess:
            (executable, arguments) => Process.start(
              executable,
              arguments,
              environment: {'TEMP': long.path, 'TMP': long.path},
            ),
      );
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.frames.first.timeout(const Duration(seconds: 15));
        final watch = Stopwatch()..start();
        final frames = await client.frames
            .takeWhile((_) => watch.elapsed < const Duration(seconds: 2))
            .length
            .timeout(const Duration(seconds: 10));
        expect(frames, greaterThan(20));
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, false) => 'the wake socket pair is Windows\' own',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'a client that reuses its pixel buffers gets the frames all the same',
    () async {
      // With reusePixels, frames from shared buffers land in three buffers
      // the client keeps, so some of eight frames share their memory.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final spinAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'spin',
        'build',
        'flutter_assets',
      );
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: spinAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint, reusePixels: true);
      try {
        final shared = await client.frames
            .where(
              (frame) => client.sharedFrames > 0 && frame.pixels.isNotEmpty,
            )
            .skip(2)
            .take(8)
            .toList()
            .timeout(const Duration(seconds: 15));
        expect(shared.last.pixels.any((byte) => byte != 0), isTrue);
        // A mark of its own written into each frame's pixels: frames that
        // share their memory then all show the last mark written there.
        // An inline frame among them keeps its own; without reuse all do.
        for (var i = 0; i < shared.length; i++) {
          (shared[i].pixels as Uint8List)[0] = i + 1;
        }
        final marks = {for (final frame in shared) frame.pixels[0]};
        expect(marks.length, lessThan(shared.length));
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'shared buffers are Unix sockets',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'a client behind the frames still gets them through the shared buffers',
    () async {
      // Busy for two frames' time with each, the client has both buffers
      // unread when the next frame comes. That frame went inline, its
      // pixels through the socket to a client already behind; it waits for
      // a buffer now.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final spinAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'spin',
        'build',
        'flutter_assets',
      );
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: spinAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.frames
            .firstWhere((_) => client.sharedFrames > 0)
            .timeout(const Duration(seconds: 15));
        final sharedBefore = client.sharedFrames;
        var frames = 0;
        final busy = client.frames.listen((_) {
          frames++;
          final spent = Stopwatch()..start();
          while (spent.elapsedMilliseconds < 35) {}
        });
        await Future<void>.delayed(const Duration(seconds: 3));
        await busy.cancel();
        expect(frames, greaterThan(20));
        // The count is taken as a frame is read and the listener hears of
        // it later, so a frame at either end may fall on the other side;
        // and a frame that waited out the runner's inline hold (100 ms) for
        // a buffer goes inline by design, which a slow host sees now and
        // then. Nine in ten through the buffers: before, most went inline.
        expect(
          client.sharedFrames - sharedBefore,
          greaterThanOrEqualTo(frames * 9 ~/ 10 - 2),
        );
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'shared buffers are Unix sockets',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'frames of a pane being dragged larger keep to the shared buffers',
    () async {
      // The buffers were sized to each frame exactly: every frame of a
      // growing pane missed them and went inline, ten megabytes through the
      // socket each, while they were made anew. They have room now.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final spinAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'spin',
        'build',
        'flutter_assets',
      );
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: spinAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      try {
        var frames = 0;
        final counting = client.frames.listen((_) => frames++);
        await client.frames
            .firstWhere((_) => client.sharedFrames > 0)
            .timeout(const Duration(seconds: 15));
        final framesBefore = frames;
        final sharedBefore = client.sharedFrames;
        for (var i = 0; i < 120; i++) {
          client.resize(1000 + i * 4, 700 + i * 3, 2.0);
          await Future<void>.delayed(const Duration(milliseconds: 16));
        }
        await counting.cancel();
        final dragged = frames - framesBefore;
        final shared = client.sharedFrames - sharedBefore;
        printOnFailure('$shared of $dragged frames shared');
        // Enough to judge by; CI's x64 Mac draws 17 in the drag.
        expect(dragged, greaterThan(5));
        expect(shared / dragged, greaterThan(0.7));
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'shared buffers are Unix sockets',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'a client nobody watches reads its frames only when asked',
    () async {
      // With no listener (a view gone with its tab), shared frames stay
      // unread in their buffer; latestFrame reads the latest when asked,
      // and a listener that comes later gets frames with pixels.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final spinAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'spin',
        'build',
        'flutter_assets',
      );
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: spinAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (client.sharedFrames < 20 && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        // Still turning: the runner gets its buffers back unread.
        expect(client.sharedFrames, greaterThanOrEqualTo(20));
        final latest = client.latestFrame;
        expect(latest?.inSharedBuffer, isFalse);
        expect(latest?.pixels.length, latest!.rowBytes * latest.height);
        expect(latest.pixels.any((byte) => byte != 0), isTrue);
        final watched = await client.frames
            .skip(1)
            .first
            .timeout(const Duration(seconds: 5));
        expect(watched.pixels.any((byte) => byte != 0), isTrue);
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'shared buffers are Unix sockets',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  // #146: a single message past the unread limit, a 4K frame inline, let
  // a client go that was reading.
  test(
    'a client reading a frame larger than the unread limit keeps its place',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
          width: 3840,
          height: 2400,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      try {
        // About 37 MB, inline: the first frame comes before shared buffers.
        final frame = await client.frames.first.timeout(
          const Duration(seconds: 20),
        );
        expect(frame.width, 3840);
        var letGo = false;
        unawaited(client.closed.then((_) => letGo = true));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(letGo, isFalse);
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );

  // #144: writes to a client that read nothing blocked the loop, the app's
  // platform thread, for up to 5 s at a time. They queue now: the runner
  // goes on, answering a newcomer at once, and the client keeps its place
  // however long it pauses, as in a debugger.
  test(
    'a client that reads nothing holds up neither the runner nor its place',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final paused = await Socket.connect(
        InternetAddress(endpoint.path, type: InternetAddressType.unix),
        0,
      );
      try {
        // Says hello, then reads nothing: its first frame, megabytes, waits
        // in the runner's queue behind a full socket.
        paused.add(
          MessageFraming.frame(
            ClientMessage(
              hello: ClientHello(protocolVersion: 1, pid: 1),
            ).writeToBuffer(),
          ),
        );
        await paused.flush();
        await Future<void>.delayed(const Duration(seconds: 1));

        // The loop is free: a newcomer is told at once that the runner is
        // taken, not after a write to the paused client gave up.
        final started = DateTime.now();
        final newcomer = await RunnerClient.connect(endpoint);
        await expectLater(
          newcomer.hello.timeout(const Duration(seconds: 2)),
          throwsA(isA<RunnerBusy>()),
        );
        expect(
          DateTime.now().difference(started),
          lessThan(const Duration(seconds: 2)),
        );
        await newcomer.close();

        // Paused past what a blocked write used to wait, it still has its
        // place, and its frame is there once it reads.
        await Future<void>.delayed(const Duration(seconds: 6));
        final received = <int>[];
        final ended = Completer<void>();
        paused.listen(received.addAll, onDone: () => ended.complete());
        final unframer = MessageUnframer();
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        var sawFrame = false;
        while (!sawFrame && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          for (final payload in unframer.add(List.of(received))) {
            if (RunnerMessage.fromBuffer(payload).hasFrame()) sawFrame = true;
          }
          received.clear();
        }
        expect(sawFrame, isTrue);
        expect(ended.isCompleted, isFalse);
        paused.add(
          MessageFraming.frame(
            ClientMessage(shutdown: Shutdown()).writeToBuffer(),
          ),
        );
        await paused.flush();
        expect(await _exitCode(runner), 0);
      } finally {
        paused.destroy();
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'a raw socket stands in for a client',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  // #138: after a client that took frames as GPU buffers, the latest frame
  // was in one, and a client that came next to an idle app got none until
  // it sent its size.
  test(
    'a client after a GPU buffer client gets a frame of its own',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      try {
        final gpu = await RunnerClient.connect(endpoint, gpuBuffers: true);
        await gpu.frames.first.timeout(const Duration(seconds: 15));
        await gpu.close();
        await Future<void>.delayed(const Duration(milliseconds: 300));

        // No resize: an idle app draws nothing for it unless the runner does.
        final next = await RunnerClient.connect(endpoint);
        final frame = await next.frames.first.timeout(
          const Duration(seconds: 5),
        );
        expect(frame.inGpuBuffer, isFalse);
        expect(frame.pixels, isNotEmpty);
        next.shutdown();
        await next.close();
        expect(await _exitCode(runner), 0);
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'a malformed plugin manifest is reported, and the app still runs',
    () async {
      // The helper writes the manifest; a field of the wrong type made the
      // runner throw at startup rather than run the app without plugins.
      for (final content in [
        '[1, 2]',
        '{"flutter_framework": 3, "plugins": [7, {"name": 1, "library": []}],'
            ' "status": [{"name": 2}, "x"]}',
      ]) {
        final temp = Directory.systemTemp.createTempSync('raccoon_test');
        final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
        final manifest = File(p.join(temp.path, 'plugins.json'))
          ..writeAsStringSync(content);
        final runner = await RunnerProcess.start(
          RunnerLaunch(
            runnerBinary: binary ?? '',
            engineDir: engineDir ?? '',
            assets: assets,
            icuData: icu ?? '',
            endpoint: endpoint,
            plugins: manifest.path,
          ),
        );
        final client = await RunnerClient.connect(endpoint);
        try {
          final frame = await client.frames.first.timeout(
            const Duration(seconds: 15),
          );
          expect(_pixel(frame, 400, 300), _red, reason: content);
        } finally {
          client.shutdown();
          await client.close();
          expect(await _exitCode(runner), 0, reason: content);
          temp.deleteSync(recursive: true);
        }
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );

  // #153: a frame that went by readback for want of a ring buffer was the
  // last an idle app drew, and a client drawing the ring drops it.
  test(
    'a GPU client takes pixel frames while it wants them, then buffers again',
    () async {
      // #202: a capture reads pixels; a GPU buffer frame has none.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint, gpuBuffers: true);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        final first = await client.frames
            .firstWhere((frame) => frame.inGpuBuffer)
            .then<Frame?>((frame) => frame)
            .timeout(const Duration(seconds: 15), onTimeout: () => null);
        // Without a GPU (a CI machine) every frame has pixels already.
        if (first == null) {
          printOnFailure('no GPU ring on this host');
          return;
        }
        client.releaseGpuBuffer(first.gpuGeneration, first.bufferIndex);
        // Two captures at once: pixels until both are done.
        client
          ..wantPixels(true)
          ..wantPixels(true);
        final pixels = await client.frames
            .firstWhere((frame) => !frame.inGpuBuffer)
            .timeout(const Duration(seconds: 15));
        expect(pixels.pixels, isNotEmpty);
        client.wantPixels(false);
        // One is still capturing: no ring yet. A redraw shows which.
        client.resize(810, 600, 1);
        final still = await client.frames.first.timeout(
          const Duration(seconds: 15),
        );
        expect(still.inGpuBuffer, isFalse);
        client.wantPixels(false);
        final again = await client.frames
            .firstWhere((frame) => frame.inGpuBuffer)
            .timeout(const Duration(seconds: 15));
        expect(again.inGpuBuffer, isTrue);
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a GPU client gets the frame it missed once it gives a buffer back',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint, gpuBuffers: true);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        // Every buffer stays with the client, so the ring runs dry.
        final held = <Frame>[];
        final readback = Completer<void>();
        final afterRelease = Completer<Frame>();
        var released = false;
        final frames = client.frames.listen((frame) {
          if (frame.inGpuBuffer) {
            if (released && !afterRelease.isCompleted) {
              afterRelease.complete(frame);
            }
            held.add(frame);
          } else if (!readback.isCompleted) {
            readback.complete();
          }
        });
        // The first frame may come inline, before the hello is read.
        final first = await client.frames
            .firstWhere((frame) => frame.inGpuBuffer)
            .then<Frame?>((frame) => frame)
            .timeout(const Duration(seconds: 15), onTimeout: () => null);
        // Without a GPU (a CI machine) the runner has no ring to run dry.
        if (first == null) {
          await frames.cancel();
          printOnFailure('no GPU ring on this host');
          return;
        }
        Future<void> tap() async {
          for (final (phase, buttons) in [
            (PointerPhase.POINTER_PHASE_DOWN, 1),
            (PointerPhase.POINTER_PHASE_UP, 0),
          ]) {
            client.sendPointer(
              PointerEvent(
                phase: phase,
                x: 400,
                y: 300,
                buttons: Int64(buttons),
                device: PointerDevice.POINTER_DEVICE_MOUSE,
                pointerId: 1,
              ),
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }

        for (var i = 0; i < 8 && !readback.isCompleted; i++) {
          await tap();
        }
        await readback.future.timeout(const Duration(seconds: 5));
        // The app is idle now; its last frame went by readback.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        released = true;
        for (final frame in held.toList()) {
          client.releaseGpuBuffer(frame.gpuGeneration, frame.bufferIndex);
        }
        final again = await afterRelease.future.timeout(
          const Duration(seconds: 3),
        );
        expect(again.inGpuBuffer, isTrue);
        await frames.cancel();
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'a view that comes back to a running app gets GPU frames again',
    () async {
      // A tab hidden: its view goes with its GPU socket, and the frames the
      // app draws meanwhile fill the ring with no one to give them back.
      // The view that comes back must not find the ring full, every frame
      // then going by readback at ten a second.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final spinAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'spin',
        'build',
        'flutter_assets',
      );
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: spinAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint, gpuBuffers: true);
      try {
        final first = await client.frames
            .firstWhere((frame) => frame.inGpuBuffer)
            .then<Frame?>((frame) => frame)
            .timeout(const Duration(seconds: 15), onTimeout: () => null);
        // Without a GPU (a CI machine) there is no ring to fill.
        if (first == null) return;
        final set = await client.gpuBufferSets.first;
        var releasing = true;
        var gpuFrames = 0;
        Frame? previous;
        final frames = client.frames.listen((frame) {
          if (!frame.inGpuBuffer) return;
          gpuFrames++;
          final last = previous;
          if (releasing && last != null) {
            client.releaseGpuBuffer(last.gpuGeneration, last.bufferIndex);
          }
          previous = frame;
        });
        Future<Socket> view() => Socket.connect(
          InternetAddress(set.socket, type: InternetAddressType.unix),
          0,
        );
        var socket = await view();
        await Future<void>.delayed(const Duration(seconds: 1));
        // The rate before the tab hid: a slow machine (CI's x64 Mac) draws
        // well under 60 a second.
        final before = gpuFrames;
        releasing = false;
        previous = null;
        socket.destroy();
        await Future<void>.delayed(const Duration(seconds: 1));
        releasing = true;
        gpuFrames = 0;
        socket = await view();
        await Future<void>.delayed(const Duration(seconds: 1));
        socket.destroy();
        await frames.cancel();
        printOnFailure('GPU frames a second: $before before, $gpuFrames after');
        // With the ring left full, none came at all. A slow machine (CI's
        // x64 Mac: 57 a second before, 23 in the first second back) takes
        // part of that second to come back up to speed.
        expect(gpuFrames, greaterThan(0));
        expect(gpuFrames, greaterThanOrEqualTo(before ~/ 4));
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );

  // #144: a client let go kept its GPU socket, which refused the next
  // client's and took its buffers.
  test(
    'a client that goes takes its GPU socket with it',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      try {
        final first = await RunnerClient.connect(endpoint, gpuBuffers: true);
        final GpuBuffers set;
        try {
          set = await first.gpuBufferSets.first.timeout(
            const Duration(seconds: 5),
          );
        } on TimeoutException {
          // No exporting renderer here: nothing to check.
          first.shutdown();
          await first.close();
          return;
        }
        // Stands in for the host's side of the GPU socket.
        final gpu = await Socket.connect(
          InternetAddress(set.socket, type: InternetAddressType.unix),
          0,
        );
        final gpuClosed = gpu.drain<void>().then((_) => true);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await first.close();
        expect(
          await gpuClosed.timeout(
            const Duration(seconds: 5),
            onTimeout: () => false,
          ),
          isTrue,
        );
        gpu.destroy();
        final last = await RunnerClient.connect(endpoint);
        await last.hello.timeout(const Duration(seconds: 5));
        last.shutdown();
        await last.close();
        expect(await _exitCode(runner), 0);
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((ready, Platform.isWindows)) {
      (false, _) => 'build the runner and example first',
      (_, true) => 'GPU sockets are Unix sockets',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'the runner stops when its parent is gone',
    () async {
      // A shell between the test and the runner stands in for the Flutter
      // tool; killing it leaves the runner without its parent. On Windows
      // the shell is cmd.exe, which waits for the runner as bash does.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final File wrapper;
      if (Platform.isWindows) {
        wrapper = File(p.join(temp.path, 'parent.cmd'))
          ..writeAsStringSync('@"$binary" %*\r\n');
      } else {
        wrapper = File(p.join(temp.path, 'parent.sh'))
          ..writeAsStringSync('#!/bin/bash\n"$binary" "\$@" &\nwait \$!\n');
        await Process.run('chmod', ['+x', wrapper.path]);
      }
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: wrapper.path,
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        Process.killPid(runner.pid, ProcessSignal.sigkill);
        await client.closed.timeout(const Duration(seconds: 5));
      } finally {
        await client.close();
        await runner.exitCode.timeout(const Duration(seconds: 10));
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'a composing client mirrors the active field and types through it',
    () async {
      final textAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'text',
        'build',
        'flutter_assets',
      );
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: textAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      runner.stderr.listen(output.add);
      final client = await RunnerClient.connect(endpoint, composes: true);
      try {
        // The field has autofocus: its state arrives as it becomes active.
        final field = await client.textFields
            .firstWhere((field) => field.active)
            .timeout(const Duration(seconds: 15));
        expect(field.text, '');
        expect(field.multiline, isFalse);
        // Waits for the whole list: 'TEXT:tiếng' contains 'TEXT:tiến', so
        // waiting for a line with the last one ended before it came.
        Future<void> texts(List<String> expected) async {
          List<String> seen() => [
            for (final line in output)
              if (line.contains('TEXT:')) line.substring(line.indexOf('TEXT:')),
          ];
          final wanted = [for (final text in expected) 'TEXT:$text'];
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          while (seen().length < wanted.length &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(seen(), wanted);
        }

        // The host's input method composes "tiế", then commits "tiếng".
        client.sendTextEditing(
          TextEditing(
            text: 'tiế',
            selectionBase: 3,
            selectionExtent: 3,
            composingBase: 0,
            composingExtent: 3,
          ),
        );
        await texts(['tiế']);
        client.sendTextEditing(
          TextEditing(
            text: 'tiếng',
            selectionBase: 5,
            selectionExtent: 5,
            composingBase: -1,
            composingExtent: -1,
          ),
        );
        await texts(['tiế', 'tiếng']);
        final mirrored = await client.textFields
            .firstWhere((field) => field.text == 'tiếng')
            .timeout(const Duration(seconds: 5));
        expect(mirrored.selectionBase, 5);
        expect(mirrored.composingBase, -1);

        // A character key types nothing for a composing client; Backspace is
        // still the framework's.
        Future<void> key(int logical, int physical, String character) async {
          for (final kind in [KeyKind.KEY_KIND_DOWN, KeyKind.KEY_KIND_UP]) {
            client.sendKey(
              KeyEvent(
                kind: kind,
                physical: Int64(physical),
                logical: Int64(logical),
                character: kind == KeyKind.KEY_KIND_DOWN ? character : '',
                timestampMicros: Int64(DateTime.now().microsecondsSinceEpoch),
              ),
            );
            await Future<void>.delayed(const Duration(milliseconds: 60));
          }
        }

        await key(0x78, 0x0007001b, 'x');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await key(0x100000008, 0x0007002a, '');
        await texts(['tiế', 'tiếng', 'tiến']);
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready &&
                Directory(
                  p.join(
                    p.dirname(p.dirname(p.dirname(assets))),
                    'text',
                    'build',
                    'flutter_assets',
                  ),
                ).existsSync()
            ? false
            : 'build the runner and the text example first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'the app sees the host\'s locales and appearance, and is resumed',
    () async {
      // A desktop embedding tells its app the host's preferred languages
      // and whether it is dark; the runner does the same after the engine
      // starts. On Linux the locales come from the environment, set here;
      // on macOS and Windows from the user's settings, read here the same
      // way.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: channelsAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
        startProcess:
            (executable, arguments) => Process.start(
              executable,
              arguments,
              environment: {'LANGUAGE': 'fr_CA:en'},
            ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!output.any((line) => line.startsWith('LIFECYCLE:')) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        // Resumed, as a desktop embedding says once the engine runs.
        expect(output, contains('LIFECYCLE:resumed'));
        // What package:raccoon reads to know it runs on Raccoon.
        expect(output, contains('RACCOON_ENDPOINT:${endpoint.uri}'));
        final locales = output.firstWhere(
          (line) => line.startsWith('LOCALES:'),
          orElse: () => 'LOCALES: none printed',
        );
        if (Platform.isMacOS) {
          expect(locales, isNot('LOCALES:'));
          // Read as apps read it, through NSUserDefaults: managed
          // preferences included, which `defaults read -g` leaves out.
          final style = await Process.run('osascript', [
            '-l',
            'JavaScript',
            '-e',
            'ObjC.import("Foundation"); '
                'var s = \$.NSUserDefaults.standardUserDefaults'
                '.stringForKey("AppleInterfaceStyle"); '
                's.isNil() ? "" : ObjC.unwrap(s)',
          ]);
          final dark = '${style.stdout}'.trim().toLowerCase() == 'dark';
          expect(output, contains('BRIGHTNESS:${dark ? 'dark' : 'light'}'));
        } else if (Platform.isWindows) {
          // The display languages and the app mode, from the user's
          // settings, as Windows apps read them.
          expect(locales, isNot('LOCALES:'));
          final mode = await Process.run('reg', [
            'query',
            r'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize',
            '/v',
            'AppsUseLightTheme',
          ]);
          final dark = RegExp(r'0x0\b').hasMatch('${mode.stdout}');
          expect(output, contains('BRIGHTNESS:${dark ? 'dark' : 'light'}'));
        } else {
          expect(locales, 'LOCALES:fr_CA,en');
          expect(output, contains('BRIGHTNESS:light'));
        }
      } finally {
        final client = await RunnerClient.connect(endpoint);
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(channelsAssets).existsSync()
            ? false
            : 'build the runner and example/channels first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a client sets the device\'s locales, text scale, dark mode, hour format '
    'and keyboard insets',
    () async {
      // #193: in place of the host's. example/channels prints DEVICE:
      // whenever they change.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: channelsAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      final client = await RunnerClient.connect(endpoint);
      Future<String> device(bool Function(String line) wanted) async {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (DateTime.now().isBefore(deadline)) {
          for (final line in output) {
            if (line.startsWith('DEVICE:') && wanted(line)) return line;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        return 'no DEVICE: line as wanted in $output';
      }

      try {
        await client.hello.timeout(const Duration(seconds: 10));
        client.resize(800, 600, 1);
        client.setViewInsets(bottom: 300);
        client.sendSettings(
          Settings(
            locales: ['de-DE', 'zh-Hans-CN'],
            textScaleFactor: 1.5,
            dark: true,
            alwaysUse24HourFormat: true,
          ),
        );
        expect(
          await device(
            (line) => line.contains('de_DE') && line.contains('1.5'),
          ),
          'DEVICE:de_DE,zh_Hans_CN;dark;1.5;true;300.0',
        );
        // A later one replaces it whole: what it leaves unset is the
        // host's again, and the insets go with the size.
        client.sendSettings(Settings(textScaleFactor: 2));
        client.setViewInsets();
        expect(
          await device(
            (line) => line.contains(';2.0;') && line.endsWith(';0.0'),
          ),
          isNot(contains('de_DE')),
        );
        // #201: a keyboard past the view is the whole view, not a size the
        // engine refuses.
        client.resize(400, 300, 1);
        client.setViewInsets(bottom: 900);
        expect(
          await device((line) => line.endsWith(';300.0')),
          endsWith(';300.0'),
        );
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(channelsAssets).existsSync()
            ? false
            : 'build the runner and example/channels first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a client puts the app in the background and back, and opens a link',
    () async {
      // #199: what a device's own controls send the app. example/channels
      // prints LIFECYCLE: and ROUTE: as they come.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: channelsAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      final client = await RunnerClient.connect(endpoint);
      Future<void> printed(String line) async {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!output.contains(line) && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(output, contains(line));
      }

      try {
        await client.hello.timeout(const Duration(seconds: 10));
        // The app's observer is in once it said what it is shown with.
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!output.any((line) => line.startsWith('DEVICE:')) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        client.setLifecycle('paused');
        await printed('LIFECYCLE:paused');
        client.setLifecycle('resumed');
        // Back in front: resumed again, after the pause.
        final deadline2 = DateTime.now().add(const Duration(seconds: 15));
        while (output.lastIndexOf('LIFECYCLE:resumed') <
                output.indexOf('LIFECYCLE:paused') &&
            DateTime.now().isBefore(deadline2)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          output.lastIndexOf('LIFECYCLE:resumed'),
          greaterThan(output.indexOf('LIFECYCLE:paused')),
        );
        client.openLink(Uri.parse('myapp://item/42?tab=reviews'));
        await printed('ROUTE:myapp://item/42?tab=reviews');
        // #209: the system back button.
        client.popRoute();
        await printed('BACK');
        // #212: a sensor reading, as sensors_plus' native side sends one:
        // a success envelope of a list of four doubles, each aligned to 8.
        final reading =
            ByteData(64)
              ..setUint8(0, 0)
              ..setUint8(1, 12)
              ..setUint8(2, 4);
        for (final (index, value) in [30.0, 9.81, 0.0, 1000.0].indexed) {
          reading
            ..setUint8(3 + 16 * index, 6)
            ..setFloat64(8 + 16 * index, value, Endian.little);
        }
        client.sendToApp(
          'dev.fluttercommunity.plus/sensors/accelerometer',
          reading.buffer.asUint8List(),
        );
        await printed('SENSOR:30.0');
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(channelsAssets).existsSync()
            ? false
            : 'build the runner and example/channels first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'an app a client put in the background is resumed when it goes',
    () async {
      // #201: the next client would find its frames off.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: channelsAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      Future<void> until(bool Function() done) async {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!done() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }

      final first = await RunnerClient.connect(endpoint);
      RunnerClient? second;
      try {
        await first.hello.timeout(const Duration(seconds: 10));
        await until(() => output.any((line) => line.startsWith('DEVICE:')));
        first.setLifecycle('paused');
        await until(() => output.contains('LIFECYCLE:paused'));
        await first.close();
        await until(
          () =>
              output.lastIndexOf('LIFECYCLE:resumed') >
              output.indexOf('LIFECYCLE:paused'),
        );
        expect(
          output.lastIndexOf('LIFECYCLE:resumed'),
          greaterThan(output.indexOf('LIFECYCLE:paused')),
        );
        second = await RunnerClient.connect(endpoint);
        await second.hello.timeout(const Duration(seconds: 10));
      } finally {
        (second ?? await RunnerClient.connect(endpoint)).shutdown();
        await second?.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(channelsAssets).existsSync()
            ? false
            : 'build the runner and example/channels first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a data directory keeps the app\'s files apart from other apps\'',
    () async {
      // On Linux, path_provider and shared_preferences are Dart only and put
      // every app hosted by one executable under the same XDG directory; the
      // runner points XDG_DATA_HOME into the app's data directory instead.
      // example/channels prints what it sees.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final dataDir = p.join(temp.path, 'data');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: channelsAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          dataDir: dataDir,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!output.any((line) => line.startsWith('XDG_DATA_HOME:')) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(
          output,
          contains('XDG_DATA_HOME:${p.join(dataDir, 'xdg', 'data')}'),
        );
      } finally {
        final client = await RunnerClient.connect(endpoint);
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch (ready && Directory(channelsAssets).existsSync()) {
      false => 'build the runner and example/channels first',
      // path_provider_windows asks the shell, which no variable moves.
      true when Platform.isWindows => 'no XDG directories on Windows',
      true => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  // example/plugins/echo is a native plugin the runner's build compiles:
  // against its own flutter_linux library on Linux, as a framework against
  // the SDK's FlutterMacOS on macOS. example/plugins_app calls it.
  final pluginLibrary =
      binary == null
          ? ''
          : p.joinAll([
            p.dirname(binary),
            'example_plugins',
            'echo',
            ...switch (Platform.operatingSystem) {
              'macos' => ['raccoon_echo.framework', 'raccoon_echo'],
              'windows' => ['raccoon_echo_plugin.dll'],
              _ => ['libraccoon_echo_plugin.so'],
            },
          ]);
  // macOS plugins link FlutterMacOS; the manifest names the SDK's, which
  // the runner opens first.
  final flutterFramework =
      sdk == null || !Platform.isMacOS
          ? null
          : p.join(
            sdk,
            'bin',
            'cache',
            'artifacts',
            'engine',
            'darwin-x64',
            'FlutterMacOS.xcframework',
            'macos-arm64_x86_64',
            'FlutterMacOS.framework',
            'FlutterMacOS',
          );
  final pluginsAppAssets = p.join(
    p.dirname(p.dirname(p.dirname(assets))),
    'plugins_app',
    'build',
    'flutter_assets',
  );
  test(
    'RACCOON_PLUGINS=cached builds nothing, off has no plugins',
    () async {
      // #214: plugins_app's echo plugin, with an empty cache and no
      // prebuilt archive: cached leaves it out and says so, off has none,
      // and once built, cached takes it.
      final temp = Directory.systemTemp.createTempSync('raccoon_plugins');
      final helper = p.join(runnerDir, 'tool', 'raccoon-device');
      final data = p.join(temp.path, 'data');
      final out = p.join(data, 'raccoon', 'apps', 'plugins_app', 'plugins');
      Future<String> install(String? mode, {bool pods = false}) async {
        final result = await Process.run(
          helper,
          ['install', pluginsAppAssets, 'plugins_app'],
          environment: {
            'RACCOON_RUNNER': binary!,
            if (sdk != null) 'FLUTTER_ROOT': sdk,
            'XDG_DATA_HOME': data,
            'XDG_RUNTIME_DIR': temp.path,
            'TMPDIR': '${temp.path}/',
            'RACCOON_PLUGIN_CACHE': p.join(temp.path, 'cache'),
            'RACCOON_NO_PREBUILT': '1',
            if (mode != null) 'RACCOON_PLUGINS': mode,
            if (pods) 'RACCOON_NO_SWIFT_PACKAGES': '1',
          },
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        return '${result.stderr}';
      }

      Map<String, String> states() {
        final manifest =
            jsonDecode(File(p.join(out, 'manifest.json')).readAsStringSync())
                as Map;
        return {
          for (final entry in (manifest['status'] as List).cast<Map>())
            '${entry['name']}': '${entry['state']}',
          for (final entry in (manifest['plugins'] as List).cast<Map>())
            '${entry['name']}': 'loaded',
        };
      }

      try {
        expect(await install('off'), contains('native plugins off'));
        expect(File(p.join(out, 'manifest.json')).existsSync(), isFalse);

        expect(
          await install('cached'),
          contains('1 not built (RACCOON_PLUGINS=cached): raccoon_echo'),
        );
        expect(states(), {'raccoon_echo': 'skipped'});
        expect(
          Directory(p.join(temp.path, 'cache', 'failed')).existsSync(),
          isFalse,
        );

        expect(await install('build'), contains('1 built: raccoon_echo'));
        expect(
          await install('cached'),
          contains('1 from the cache: raccoon_echo'),
        );
        expect(states(), {'raccoon_echo': 'loaded'});

        if (Platform.isMacOS) {
          // #225: a CocoaPods entry records the keys of the plugins it
          // carries; one recorded with a key this app's plugin no longer
          // has is built again.
          expect(
            await install('build', pods: true),
            contains('1 built: raccoon_echo'),
          );
          final record = Directory(p.join(temp.path, 'cache'))
              .listSync(recursive: true)
              .whereType<File>()
              .singleWhere(
                (file) =>
                    p.basename(file.path) == '.plugins.json' &&
                    p.basename(file.parent.path).startsWith('raccoon_echo-'),
              );
          expect(record.readAsStringSync(), '{}');
          record.writeAsStringSync('{"raccoon_echo": "an older key"}');
          expect(
            await install('cached', pods: true),
            contains('1 not built (RACCOON_PLUGINS=cached): raccoon_echo'),
          );
          expect(
            await install('build', pods: true),
            contains('1 built: raccoon_echo'),
          );
          expect(record.readAsStringSync(), '{}');
        }

        // Where the environment says none, the host's default, then the
        // app's own over it; the environment's wins over both.
        final saved = AppPlugins(p.join(data, 'raccoon', 'data'));
        saved.saveDefault(NativePlugins.off);
        expect(await install(null), contains('native plugins off'));
        // An app's file that says none of the three is passed over.
        File(p.join(data, 'raccoon', 'data', 'plugins_app', 'plugins'))
          ..createSync(recursive: true)
          ..writeAsStringSync('sometimes\n');
        expect(await install(null), contains('native plugins off'));
        saved.save('plugins_app', NativePlugins.cached);
        expect(await install(null), contains('1 from the cache: raccoon_echo'));
        saved.save('plugins_app', NativePlugins.off);
        expect(
          await install('cached'),
          contains('1 from the cache: raccoon_echo'),
        );
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((
      binary != null && sdk != null && Directory(pluginsAppAssets).existsSync(),
      Platform.isWindows,
    )) {
      (false, _) => 'build the runner and example/plugins_app first',
      (_, true) => 'the helper runs in Git Bash on Windows',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
  test(
    'on macOS a plugin with a Swift package is built through it and answers',
    () async {
      // #187: example/plugins/echo has a Package.swift beside its podspec,
      // as Flutter's plugin template makes one; the helper builds it with
      // the app's other Swift packages into one framework.
      final temp = Directory.systemTemp.createTempSync('raccoon_swiftpm');
      final helper = p.join(runnerDir, 'tool', 'raccoon-device');
      final data = p.join(temp.path, 'data');
      Map<String, String> environment({bool pods = false}) => {
        'RACCOON_RUNNER': binary!,
        if (sdk != null) 'FLUTTER_ROOT': sdk,
        'XDG_DATA_HOME': data,
        'XDG_RUNTIME_DIR': temp.path,
        'TMPDIR': '${temp.path}/',
        'RACCOON_PLUGIN_CACHE': p.join(temp.path, 'cache'),
        'RACCOON_NO_PREBUILT': '1',
        if (pods) 'RACCOON_NO_SWIFT_PACKAGES': '1',
      };
      Future<(String, String)> install({bool pods = false}) async {
        final result = await Process.run(helper, [
          'install',
          pluginsAppAssets,
          'plugins_app',
        ], environment: environment(pods: pods));
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final manifest =
            jsonDecode(
                  File(
                    p.join(
                      data,
                      'raccoon',
                      'apps',
                      'plugins_app',
                      'plugins',
                      'manifest.json',
                    ),
                  ).readAsStringSync(),
                )
                as Map;
        final echo = (manifest['plugins'] as List).cast<Map>().singleWhere(
          (entry) => entry['name'] == 'raccoon_echo',
        );
        return ('${result.stderr}', '${echo['library']}');
      }

      try {
        final (built, library) = await install();
        expect(built, contains('1 built: raccoon_echo'));
        expect(library, endsWith('RaccoonPlugins.framework/RaccoonPlugins'));
        // Checkouts stay for the next build (#188).
        expect(
          Directory(p.join(temp.path, 'cache', 'swiftpm-sources')).existsSync(),
          isTrue,
        );
        final run = await Process.start(helper, [
          'run',
          'plugins_app',
        ], environment: environment());
        final lines = <String>[];
        run.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(lines.add);
        run.stderr.drain<void>().ignore();
        try {
          final deadline = DateTime.now().add(const Duration(seconds: 30));
          while (!lines.any((line) => line.contains('ECHO:')) &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(lines, contains('ECHO:echo: hello'));
        } finally {
          run.kill();
          await run.exitCode;
        }

        final (again, _) = await install();
        expect(again, contains('1 from the cache: raccoon_echo'));
        // Turned off, the podspec builds it as before.
        final (_, pods) = await install(pods: true);
        expect(pods, endsWith('raccoon_echo.framework/raccoon_echo'));
        // Every one of them a pod in the cache (the release's prebuilt
        // plugins): those, rather than a build.
        for (final entry in Directory(p.join(temp.path, 'cache')).listSync()) {
          if (p.basename(entry.path).startsWith('swiftpm-')) {
            entry.deleteSync(recursive: true);
          }
        }
        final (cached, podLibrary) = await install();
        expect(cached, contains('1 from the cache: raccoon_echo'));
        expect(podLibrary, endsWith('raccoon_echo.framework/raccoon_echo'));

        // The release's prebuilt plugins are one pod each, which an install
        // can take; never a build of a whole set (#189).
        final archive = p.join(temp.path, 'prebuilt.tar.gz');
        final prebuild = await Process.run(helper, [
          'prebuild',
          p.dirname(p.dirname(pluginsAppAssets)),
          archive,
        ], environment: environment());
        expect(prebuild.exitCode, 0, reason: '${prebuild.stderr}');
        final listing =
            '${(await Process.run('tar', ['tzf', archive])).stdout}';
        expect(listing, contains('raccoon_echo.framework/'));
        expect(listing, isNot(contains('swiftpm-')));
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch ((
      binary != null && sdk != null && Directory(pluginsAppAssets).existsSync(),
      Platform.isMacOS,
    )) {
      (false, _) => 'build the runner and example/plugins_app first',
      (_, false) => 'Swift packages are a macOS build',
      _ => false,
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
  test(
    'a native plugin loaded into the runner answers the app',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final manifest = File(p.join(temp.path, 'plugins.json'))
        ..writeAsStringSync(
          jsonEncode({
            if (flutterFramework != null) 'flutter_framework': flutterFramework,
            'plugins': [
              _pluginEntry('raccoon_echo', pluginLibrary, 'RaccoonEchoPlugin'),
            ],
          }),
        );
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: pluginsAppAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          plugins: manifest.path,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!output.any((line) => line.startsWith('SECURE:')) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        // The plugin answers from GLib's main loop on Linux, the main queue on
        // macOS, the platform thread's messages on Windows: the runner turns
        // the plugins' main loop.
        expect(output, contains('ECHO:echo: hello'));
        // Plugins are called on a thread in a single-threaded apartment,
        // which shell dialogs need (#126).
        if (Platform.isWindows) expect(output, contains('APARTMENT:sta'));
        // flutter_secure_storage's options reach the plugin without what an
        // unsigned process can't have: the login keychain, no access group,
        // no iCloud sync (#87).
        if (Platform.isMacOS) {
          expect(
            output,
            contains(
              'SECURE:accountName=app;synchronizable=false;'
              'useDataProtectionKeyChain=false;usesDataProtectionKeychain=false',
            ),
          );
        }
      } finally {
        final client = await RunnerClient.connect(endpoint);
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready &&
                File(pluginLibrary).existsSync() &&
                Directory(pluginsAppAssets).existsSync()
            ? false
            : 'build the runner with plugins and example/plugins_app first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  // example/plugins_modal animates, then asks the echo plugin for a message
  // box that closes itself after two seconds.
  final pluginsModalAssets = p.join(
    p.dirname(p.dirname(p.dirname(assets))),
    'plugins_modal',
    'build',
    'flutter_assets',
  );
  test(
    'frames keep coming while a plugin\'s modal dialog runs its own loop',
    () async {
      // A modal dialog's loop holds the runner's until it closes: a message
      // loop on Windows, the run loop in its modal panel mode on macOS, a
      // nested GLib loop on Linux. The runner takes its turns from a timer
      // meanwhile.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final manifest = File(p.join(temp.path, 'plugins.json'))
        ..writeAsStringSync(
          jsonEncode({
            if (flutterFramework != null) 'flutter_framework': flutterFramework,
            'plugins': [
              _pluginEntry('raccoon_echo', pluginLibrary, 'RaccoonEchoPlugin'),
            ],
          }),
        );
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: pluginsModalAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          plugins: manifest.path,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      var modal = false;
      var during = 0;
      final done = Completer<String>();
      runner.stdout.listen((line) {
        if (line.contains('MODAL:start')) modal = true;
        if (line.contains('MODAL:done') || line.contains('MODAL:error')) {
          modal = false;
          if (!done.isCompleted) done.complete(line);
        }
      });
      final frames = client.frames.listen((_) {
        if (modal) during++;
      });
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        expect(
          await done.future.timeout(const Duration(seconds: 20)),
          contains('MODAL:done'),
        );
        // Two seconds at 60 Hz are 120 frames; a held loop sends none, so
        // 10 tells them apart on a loaded CI runner too (one drew 27).
        expect(during, greaterThan(10));
      } finally {
        await frames.cancel();
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready &&
                File(pluginLibrary).existsSync() &&
                Directory(pluginsModalAssets).existsSync()
            ? false
            : 'build the runner with plugins and example/plugins_modal first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'an FFI plugin\'s framework is opened for Dart and reported loaded',
    () async {
      // macOS: no class to register, only a framework whose symbols Dart
      // finds in the process or by name. The echo framework stands in.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final manifest = File(p.join(temp.path, 'plugins.json'))
        ..writeAsStringSync(
          jsonEncode({
            'flutter_framework': flutterFramework,
            'plugins': [
              {'name': 'echo_ffi', 'library': pluginLibrary, 'ffi': true},
            ],
          }),
        );
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: pluginsAppAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          plugins: manifest.path,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        final plugins = await client.plugins.first.timeout(
          const Duration(seconds: 10),
        );
        expect(plugins.plugins.single.state, PluginState.PLUGIN_STATE_LOADED);
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isMacOS
            ? 'FFI entries are macOS manifests'
            : ready &&
                File(pluginLibrary).existsSync() &&
                Directory(pluginsAppAssets).existsSync()
            ? false
            : 'build the runner with plugins and example/plugins_app first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'classes two plugins both carry are said once for the two',
    () async {
      // #198: a pod and a package of the same SDK each link it, and the
      // runtime printed a line per class, 25 for Firebase and Google
      // Sign-In. Two libraries with the same two classes stand in.
      final temp = Directory.systemTemp.createTempSync('raccoon_twins');
      final libraries = <String>[];
      for (final name in ['twin_a', 'twin_b']) {
        final source = File(p.join(temp.path, '$name.m'))..writeAsStringSync(
          '#import <Foundation/Foundation.h>\n'
          '@interface RaccoonTwinOne : NSObject\n@end\n'
          '@implementation RaccoonTwinOne\n@end\n'
          '@interface RaccoonTwinTwo : NSObject\n@end\n'
          '@implementation RaccoonTwinTwo\n@end\n',
        );
        final library = p.join(temp.path, 'lib$name.dylib');
        final built = await Process.run('clang', [
          '-dynamiclib',
          '-framework',
          'Foundation',
          source.path,
          '-o',
          library,
        ]);
        expect(built.exitCode, 0, reason: '${built.stderr}');
        libraries.add(library);
      }
      final manifest = File(p.join(temp.path, 'plugins.json'))
        ..writeAsStringSync(
          jsonEncode({
            'flutter_framework': flutterFramework,
            'plugins': [
              for (final (index, library) in libraries.indexed)
                {
                  'name': 'twin_$index',
                  'library': library,
                  'class': 'RaccoonTwinOne',
                },
            ],
          }),
        );
      // Rendered once: its stderr whole, the lines from loading the
      // plugins, which come before a served runner listens, included.
      try {
        final render = await Process.run(binary!, [
          'render',
          '--engine-dir',
          engineDir!,
          '--assets',
          pluginsAppAssets,
          '--icu',
          icu!,
          '--plugins',
          manifest.path,
          '--out',
          p.join(temp.path, 'frame.ppm'),
        ]);
        final stderr = '${render.stderr}';
        expect(stderr, isNot(contains('is implemented in both')));
        expect(
          stderr,
          contains(
            '🦝 2 Objective-C classes are in both libtwin_a.dylib and '
            'libtwin_b.dylib (RaccoonTwinOne, RaccoonTwinTwo); each calls its '
            'own copy, a lookup by name gets either',
          ),
        );
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isMacOS
            ? 'Objective-C classes are macOS'
            : ready &&
                flutterFramework != null &&
                Directory(pluginsAppAssets).existsSync()
            ? false
            : 'build the runner with plugins and example/plugins_app first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a plugin library that dies as it loads still says why',
    () async {
      // #201: stderr is held while a library maps (#198); a fatal signal
      // writes back what was held before the runner dies.
      final temp = Directory.systemTemp.createTempSync('raccoon_boom');
      final source = File(p.join(temp.path, 'boom.c'))..writeAsStringSync(
        '#include <stdio.h>\n#include <stdlib.h>\n'
        '__attribute__((constructor)) static void boom(void) {\n'
        '  fprintf(stderr, "RACCOON_BOOM: the reason\\n");\n'
        '  abort();\n}\n',
      );
      final library = p.join(temp.path, 'libboom.dylib');
      final built = await Process.run('clang', [
        '-dynamiclib',
        source.path,
        '-o',
        library,
      ]);
      expect(built.exitCode, 0, reason: '${built.stderr}');
      final manifest = File(p.join(temp.path, 'plugins.json'))
        ..writeAsStringSync(
          jsonEncode({
            'flutter_framework': flutterFramework,
            'plugins': [
              {'name': 'boom', 'library': library, 'class': 'Boom'},
            ],
          }),
        );
      try {
        final render = await Process.run(binary!, [
          'render',
          '--engine-dir',
          engineDir!,
          '--assets',
          pluginsAppAssets,
          '--icu',
          icu!,
          '--plugins',
          manifest.path,
          '--out',
          p.join(temp.path, 'frame.ppm'),
        ]);
        expect(render.exitCode, isNot(0));
        expect('${render.stderr}', contains('RACCOON_BOOM: the reason'));
        // Serving, stderr goes through a pipe the runner reads: the reason
        // reached it, and died with it more often than not (#231). A few
        // runs, as it was a race.
        for (var run = 0; run < 3; run++) {
          final serve = await Process.run(binary, [
            'serve',
            '--engine-dir',
            engineDir,
            '--assets',
            pluginsAppAssets,
            '--icu',
            icu,
            '--plugins',
            manifest.path,
            '--socket',
            p.join(temp.path, 'boom.sock'),
          ]).timeout(const Duration(seconds: 30));
          expect(serve.exitCode, isNot(0));
          expect(
            '${serve.stderr}',
            contains('RACCOON_BOOM: the reason'),
            reason: 'run $run',
          );
        }
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isMacOS
            ? 'held stderr is macOS'
            : ready &&
                flutterFramework != null &&
                Directory(pluginsAppAssets).existsSync()
            ? false
            : 'build the runner with plugins and example/plugins_app first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'the runner tells a client what became of the plugins',
    () async {
      // The manifest carries the helper's word on what never got as far as a
      // library; the runner adds its own on what it loaded, and sends the
      // lot after Hello.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final manifest = File(p.join(temp.path, 'plugins.json'))
        ..writeAsStringSync(
          jsonEncode({
            if (flutterFramework != null) 'flutter_framework': flutterFramework,
            'plugins': [
              _pluginEntry('raccoon_echo', pluginLibrary, 'RaccoonEchoPlugin'),
              _pluginEntry(
                'nowhere',
                p.join(temp.path, 'libnowhere_plugin.so'),
                'NowherePlugin',
              ),
            ],
            'status': [
              {
                'name': 'firebase_core',
                'state': 'no_host',
                'detail': 'no Linux implementation',
              },
              {
                'name': 'desktop_window',
                'state': 'built_in',
                'detail': 'the runner answers it',
              },
              {
                'name': 'geolocator_apple',
                'state': 'skipped',
                'detail': 'not built: native plugins are cached only',
              },
            ],
          }),
        );
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: pluginsAppAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          plugins: manifest.path,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      // The runner's stderr from before the first frame, relayed.
      final logs = <String>[];
      final logged = client.messages
          .where((m) => m.hasLog())
          .listen((m) => logs.add(m.log.message));
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        final plugins = await client.plugins.first.timeout(
          const Duration(seconds: 10),
        );
        final byName = {for (final s in plugins.plugins) s.name: s};
        expect(byName['raccoon_echo']?.state, PluginState.PLUGIN_STATE_LOADED);
        expect(byName['nowhere']?.state, PluginState.PLUGIN_STATE_FAILED);
        expect(byName['nowhere']?.detail, contains('libnowhere_plugin.so'));
        expect(
          byName['firebase_core']?.state,
          PluginState.PLUGIN_STATE_NO_HOST,
        );
        expect(
          byName['desktop_window']?.state,
          PluginState.PLUGIN_STATE_BUILT_IN,
        );
        expect(
          byName['geolocator_apple']?.state,
          PluginState.PLUGIN_STATE_SKIPPED,
        );
        expect(client.latestPlugins, plugins);
        if (Platform.isMacOS) {
          // FlutterMacOS shares classes with the engine library; the
          // runtime's line for each is left out, one line says so.
          await Future<void>.delayed(const Duration(seconds: 1));
          expect(
            logs.where((l) => l.contains('is implemented in both')),
            isEmpty,
          );
          expect(logs, contains(contains('FlutterMacOS shares')));
        }
      } finally {
        await logged.cancel();
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready &&
                File(pluginLibrary).existsSync() &&
                Directory(pluginsAppAssets).existsSync()
            ? false
            : 'build the runner with plugins and example/plugins_app first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a plugin\'s texture draws through the renderer',
    () async {
      // The echo plugin registers a 64 by 64 pixel-buffer texture, orange;
      // example/plugins_app draws it full screen. The frame a client reads
      // back is then orange: the texture went through the GPU renderer (GL
      // on Linux, Metal on macOS) and the compositor. The software renderer
      // takes no textures.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final manifest = File(p.join(temp.path, 'plugins.json'))
        ..writeAsStringSync(
          jsonEncode({
            if (flutterFramework != null) 'flutter_framework': flutterFramework,
            'plugins': [
              _pluginEntry('raccoon_echo', pluginLibrary, 'RaccoonEchoPlugin'),
            ],
          }),
        );
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: pluginsAppAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          plugins: manifest.path,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!output.any((line) => line.startsWith('TEXTURE:')) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        if (runner.renderer != 'gl' && runner.renderer != 'metal') {
          printOnFailure(
            'software renderer, no textures: ${output.join('\n')}',
          );
          // Linux's registrar refuses the texture. FlutterMacOS's has no way
          // to: the id comes back and nothing draws.
          if (!Platform.isMacOS) {
            expect(output, contains(startsWith('TEXTURE:error')));
          }
          return;
        }
        expect(output, contains(startsWith('TEXTURE:')));
        final orange = await client.frames
            .firstWhere(
              (f) => _pixel(f, 400, 300) == (r: 0xFF, g: 0x8C, b: 0x00),
            )
            .timeout(const Duration(seconds: 15));
        expect(_pixel(orange, 5, 5), (r: 0xFF, g: 0x8C, b: 0x00));
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready &&
                File(pluginLibrary).existsSync() &&
                Directory(pluginsAppAssets).existsSync()
            ? false
            : 'build the runner with plugins and example/plugins_app first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a texture unregistered is told so on the raster thread',
    () async {
      // #231: FlutterMacOS tells a texture it was unregistered on the
      // raster thread; the host told it on whichever thread unregistered
      // it, and kept its last frame until another texture drew.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final manifest = File(p.join(temp.path, 'plugins.json'))
        ..writeAsStringSync(
          jsonEncode({
            'flutter_framework': flutterFramework,
            'plugins': [
              _pluginEntry('raccoon_echo', pluginLibrary, 'RaccoonEchoPlugin'),
            ],
          }),
        );
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: pluginsAppAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          plugins: manifest.path,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        await client.frames.first.timeout(const Duration(seconds: 15));
        expect(output, contains(startsWith('TEXTURE:')));
        client.sendToApp('raccoon_echo_app', utf8.encode('untexture'));
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!output.any((line) => line.startsWith('UNTEXTURE:')) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        printOnFailure(output.join('\n'));
        expect(output, contains('UNTEXTURE:raster'));
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isMacOS
            ? 'onTextureUnregistered: is FlutterMacOS\'s'
            : ready &&
                flutterFramework != null &&
                File(pluginLibrary).existsSync() &&
                Directory(pluginsAppAssets).existsSync()
            ? false
            : 'build the runner with plugins and example/plugins_app first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  // Built beside the runner: the channels it answers itself, fed random
  // and broken input (test/channels_check.cc).
  final channelsCheck =
      binary == null
          ? ''
          : p.join(
            p.dirname(binary),
            Platform.isWindows
                ? 'raccoon_channels_check.exe'
                : 'raccoon_channels_check',
          );
  test(
    'the channels the runner answers itself hold up to random input',
    () async {
      final check = await Process.run(channelsCheck, const []);
      printOnFailure('${check.stdout}${check.stderr}');
      expect(check.exitCode, 0);
      expect('${check.stdout}', contains('CHANNELS ok'));
    },
    skip:
        File(channelsCheck).existsSync()
            ? false
            : 'build the runner\'s channels check first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  // Built beside the runner on macOS: a GPU socket client that takes the
  // ring's surfaces by Mach port and checks them.
  final portCheck =
      binary == null ? '' : p.join(p.dirname(binary), 'raccoon_gpu_port_check');
  test(
    'on macOS the GPU socket hands out surfaces by Mach port, not global IDs',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final spinAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'spin',
        'build',
        'flutter_assets',
      );
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: spinAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint, gpuBuffers: true);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        final set = await client.gpuBufferSets.first.timeout(
          const Duration(seconds: 10),
        );
        // Buffers go back as frames come, so the ring keeps turning.
        Frame? previous;
        final frames = client.frames.listen((frame) {
          final last = previous;
          if (last != null && last.inGpuBuffer) {
            client.releaseGpuBuffer(last.gpuGeneration, last.bufferIndex);
          }
          previous = frame;
        });
        final check = await Process.run(portCheck, [set.socket]);
        await frames.cancel();
        printOnFailure('${check.stdout}${check.stderr}');
        expect(check.exitCode, 0);
        expect('${check.stdout}', contains('PORTS ok'));
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isMacOS
            ? 'Mach ports are macOS'
            : ready && File(portCheck).existsSync()
            ? false
            : 'build the runner and its port check first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'on macOS a client that never reaches the port service keeps global surfaces',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final spinAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'spin',
        'build',
        'flutter_assets',
      );
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: spinAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint, gpuBuffers: true);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        final set = await client.gpuBufferSets.first.timeout(
          const Duration(seconds: 10),
        );
        // Buffers go back as frames come, so the ring keeps turning.
        Frame? previous;
        final frames = client.frames.listen((frame) {
          final last = previous;
          if (last != null && last.inGpuBuffer) {
            client.releaseGpuBuffer(last.gpuGeneration, last.bufferIndex);
          }
          previous = frame;
        });
        // A sandboxed host's lookup fails: it takes the answer, asks
        // nothing, and must still find the surfaces by ID.
        final check = await Process.run(portCheck, [set.socket, '--never-ask']);
        await frames.cancel();
        printOnFailure('${check.stdout}${check.stderr}');
        expect(check.exitCode, 0);
        expect('${check.stdout}', contains('GLOBAL ok'));
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isMacOS
            ? 'Mach ports are macOS'
            : ready && File(portCheck).existsSync()
            ? false
            : 'build the runner and its port check first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'on macOS a token given to one client is not good after the next answer',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final spinAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'spin',
        'build',
        'flutter_assets',
      );
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: spinAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint, gpuBuffers: true);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        final set = await client.gpuBufferSets.first.timeout(
          const Duration(seconds: 10),
        );
        // Buffers go back as frames come, so the ring keeps turning.
        Frame? previous;
        final frames = client.frames.listen((frame) {
          final last = previous;
          if (last != null && last.inGpuBuffer) {
            client.releaseGpuBuffer(last.gpuGeneration, last.bufferIndex);
          }
          previous = frame;
        });
        // #161: a request from a client that has gone, still queued, must
        // not count as the next client's ask.
        final check = await Process.run(portCheck, [set.socket, '--renew']);
        await frames.cancel();
        printOnFailure('${check.stdout}${check.stderr}');
        expect(check.exitCode, 0);
        expect('${check.stdout}', contains('RENEW ok'));
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isMacOS
            ? 'Mach ports are macOS'
            : ready && File(portCheck).existsSync()
            ? false
            : 'build the runner and its port check first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'on macOS the rings go global again for the client after one that took ports',
    () async {
      // #153: a client that cannot reach the service, after one that made
      // the rings private, must find its surfaces by ID again.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final spinAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'spin',
        'build',
        'flutter_assets',
      );
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: spinAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      try {
        for (final mode in ['', '--never-ask']) {
          // The runner may not have seen the last client go yet, and
          // answers Busy until it has.
          late RunnerClient client;
          for (var attempt = 0; ; attempt++) {
            client = await RunnerClient.connect(endpoint, gpuBuffers: true);
            try {
              await client.hello;
              break;
            } on RunnerBusy {
              await client.close();
              if (attempt == 20) rethrow;
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          }
          final set = await client.gpuBufferSets.first.timeout(
            const Duration(seconds: 10),
          );
          Frame? previous;
          final frames = client.frames.listen((frame) {
            final last = previous;
            if (last != null && last.inGpuBuffer) {
              client.releaseGpuBuffer(last.gpuGeneration, last.bufferIndex);
            }
            previous = frame;
          });
          final check = await Process.run(portCheck, [
            set.socket,
            if (mode.isNotEmpty) mode,
          ]);
          await frames.cancel();
          printOnFailure('$mode: ${check.stdout}${check.stderr}');
          expect(check.exitCode, 0, reason: mode);
          await client.close();
        }
      } finally {
        final client = await RunnerClient.connect(endpoint);
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isMacOS
            ? 'Mach ports are macOS'
            : ready && File(portCheck).existsSync()
            ? false
            : 'build the runner and its port check first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  // Built beside the runner on Windows: a GPU socket client that opens the
  // ring's textures by their shared handles and checks the frame in them.
  final handleCheck =
      binary == null
          ? ''
          : p.join(p.dirname(binary), 'raccoon_gpu_handle_check.exe');
  test(
    'on Windows a client opens the ring by its shared handles and finds the frame',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: assets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint, gpuBuffers: true);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        // Without a Vulkan device (a CI machine) the runner rasterizes in
        // software and offers no textures: nothing to open.
        if (runner.renderer != 'vulkan') {
          printOnFailure('renderer ${runner.renderer}, no shared textures');
          return;
        }
        final set = await client.gpuBufferSets.first.timeout(
          const Duration(seconds: 10),
        );
        await client.frames
            .firstWhere((frame) => frame.inGpuBuffer)
            .timeout(const Duration(seconds: 10));
        final check = await Process.run(handleCheck, [set.socket]);
        printOnFailure('${check.stdout}${check.stderr}');
        expect(check.exitCode, 0);
        expect('${check.stdout}', contains('HANDLES ok'));
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        !Platform.isWindows
            ? 'shared D3D11 textures are Windows'
            : ready && File(handleCheck).existsSync()
            ? false
            : 'build the runner and its handle check first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a client that imports GPU buffers gets frames as buffer indices and their descriptors on the GPU socket',
    () async {
      // The spin example animates, so frames keep coming.
      final spinAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'spin',
        'build',
        'flutter_assets',
      );
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: spinAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final client = await RunnerClient.connect(endpoint, gpuBuffers: true);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        // Only a renderer that exports offers them; otherwise frames come by
        // readback and the test has nothing to check.
        final GpuBuffers set;
        try {
          set = await client.gpuBufferSets.first.timeout(
            const Duration(seconds: 5),
          );
        } on TimeoutException {
          final frame = await client.frames.first.timeout(
            const Duration(seconds: 10),
          );
          expect(frame.inGpuBuffer, isFalse);
          printOnFailure('no GPU buffers offered: ${client.latestGpuBuffers}');
          return;
        }
        expect(set.count, 4);
        expect(set.generation, greaterThan(0));
        expect(set.width, 800);
        expect(set.height, 600);
        expect(set.strides, hasLength(4));
        expect(set.socket, p.join(temp.path, 'runner.gpu'));

        // Frames are indices now, no pixels; giving them back keeps them
        // coming past the ring's size.
        final frames = <Frame>[];
        final done = Completer<void>();
        // Later, buffers go back over the GPU socket instead.
        late RawSocket gpuSocket;
        var releaseOnSocket = false;
        final socketFrames = <Frame>[];
        final doneOnSocket = Completer<void>();
        // Last, buffers are held: the ring starves, then the GPU socket's
        // client goes away and they are the runner's again.
        var hold = false;
        final starved = Completer<void>();
        final freed = Completer<void>();
        var afterStarving = 0;
        final subscription = client.frames.listen((frame) {
          frames.add(frame);
          if (hold) {
            if (!frame.inGpuBuffer && !starved.isCompleted) starved.complete();
            if (frame.inGpuBuffer && starved.isCompleted) afterStarving++;
            if (afterStarving >= 2 && !freed.isCompleted) freed.complete();
            return;
          }
          if (frame.inGpuBuffer) {
            if (releaseOnSocket) {
              socketFrames.add(frame);
              gpuSocket.write(_release(frame.gpuGeneration, frame.bufferIndex));
              if (socketFrames.length >= 8 && !doneOnSocket.isCompleted) {
                doneOnSocket.complete();
              }
            } else {
              client.releaseGpuBuffer(frame.gpuGeneration, frame.bufferIndex);
            }
          }
          if (frames.length >= 8 && !done.isCompleted) done.complete();
        });
        await done.future.timeout(const Duration(seconds: 15));
        expect(frames.where((f) => f.inGpuBuffer), isNotEmpty);
        expect(
          frames.where((f) => f.inGpuBuffer).every((f) => f.pixels.isEmpty),
          isTrue,
        );
        expect(
          frames
              .where((f) => f.inGpuBuffer)
              .map((f) => f.bufferIndex)
              .toSet()
              .length,
          greaterThan(1),
        );

        // The GPU socket serves the same description: on Linux with one
        // descriptor per buffer riding along, on macOS with the surfaces'
        // IDs after the pairs and nothing riding along, on Windows with the
        // textures' shared handles there instead.
        gpuSocket = await RawSocket.connect(
          InternetAddress(set.socket, type: InternetAddressType.unix),
          0,
        );
        final handles = <ResourceHandle>[];
        final bytes = <int>[];
        final described = Completer<void>();
        gpuSocket.listen((event) {
          if (event != RawSocketEvent.read) return;
          if (Platform.isWindows) {
            bytes.addAll(gpuSocket.read() ?? const []);
          } else {
            final message = gpuSocket.readMessage();
            if (message == null) return;
            bytes.addAll(message.data);
            for (final control in message.controlMessages) {
              handles.addAll(control.extractHandles());
            }
          }
          final whole = MessageUnframer()
              .add(Uint8List.fromList(bytes))
              .any((m) => String.fromCharCodes(m.sublist(0, 4)) == 'RGPU');
          if (whole &&
              (!Platform.isLinux || handles.length >= 4) &&
              !described.isCompleted) {
            described.complete();
          }
        });
        await described.future.timeout(const Duration(seconds: 10));
        final messages =
            MessageUnframer().add(Uint8List.fromList(bytes)).toList();
        expect(messages, isNotEmpty);
        // A fixed layout, so a native client needs no protobuf.
        final data = ByteData.sublistView(messages.first);
        expect(String.fromCharCodes(messages.first.sublist(0, 4)), 'RGPU');
        expect(data.getUint32(4, Endian.little), set.generation);
        expect(data.getUint32(8, Endian.little), 4);
        expect(data.getUint32(12, Endian.little), set.width);
        expect(data.getUint32(16, Endian.little), set.height);
        expect(data.getUint32(20, Endian.little), set.fourcc);
        if (!Platform.isLinux) {
          expect(messages.first.length, 32 + 4 * 8 + 4 * 4);
          final ids = [
            for (var i = 0; i < 4; i++)
              data.getUint32(32 + 4 * 8 + i * 4, Endian.little),
          ];
          expect(ids.toSet(), hasLength(4));
          expect(ids, everyElement(isNot(0)));
          expect(handles, isEmpty);
        } else {
          expect(messages.first.length, 32 + 4 * 8);
          expect(handles.length, greaterThanOrEqualTo(4));
        }

        // Where EGL has native fences, each frame's fence comes ahead of it:
        // 'RFEN', generation, index, one descriptor riding along. Metal
        // names a frame once it is drawn instead, so there are none.
        List<Uint8List> fences() =>
            MessageUnframer()
                .add(Uint8List.fromList(bytes))
                .where((m) => String.fromCharCodes(m.sublist(0, 4)) == 'RFEN')
                .toList();
        final deadline = DateTime.now().add(
          Platform.isMacOS ? Duration.zero : const Duration(seconds: 3),
        );
        while (fences().isEmpty && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        final fenced = fences();
        final handleCount = handles.length;
        if (fenced.isEmpty) {
          printOnFailure('no fences from this renderer');
        } else {
          expect(fenced.every((m) => m.length == 12), isTrue);
          expect(
            fenced
                .map((m) => ByteData.sublistView(m).getUint32(4, Endian.little))
                .toSet(),
            {set.generation},
          );
          expect(handleCount, 4 + fenced.length);
        }

        // Buffers can be given back on this socket too: 'RREL', generation,
        // index, fenced; frames keep coming past the ring's size.
        releaseOnSocket = true;
        await doneOnSocket.future.timeout(const Duration(seconds: 15));
        expect(
          socketFrames.map((f) => f.bufferIndex).toSet().length,
          greaterThan(1),
        );

        // Held buffers starve the ring into readback; once the client on
        // the GPU socket is gone, the runner takes them all back.
        hold = true;
        await starved.future.timeout(const Duration(seconds: 15));
        await gpuSocket.close();
        await freed.future.timeout(const Duration(seconds: 15));
        await subscription.cancel();
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip: ready ? false : 'build the runner and example first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  // example/no_plugin calls a Pigeon channel nobody serves in main(), before
  // runApp, and dies of the null reply; example/no_plugin_late draws first,
  // then calls a method channel nobody serves, and again on every tap.
  final noPluginAssets = p.join(
    runnerDir,
    'example',
    'no_plugin',
    'build',
    'flutter_assets',
  );
  final noPluginLateAssets = p.join(
    runnerDir,
    'example',
    'no_plugin_late',
    'build',
    'flutter_assets',
  );
  const pigeonChannel =
      'dev.flutter.pigeon.absent_plugin.AbsentHostApi.initialize';
  const lateChannel = 'plugins.flutter.io/absent_plugin';
  const orange = (r: 0xFB, g: 0x8C, b: 0x00);
  const grey = (r: 0x9E, g: 0x9E, b: 0x9E);

  /// How long the app took for its call, from what it printed last with
  /// [prefix], such as `NO_PLUGIN:null after 3 ms`.
  int? replyMillis(Iterable<String> lines, String prefix) {
    final printed = lines.where((line) => line.contains(prefix)).lastOrNull;
    if (printed == null) return null;
    final match = RegExp(r'after (\d+) ms').firstMatch(printed);
    return int.tryParse(match?.group(1) ?? '');
  }

  test(
    'a call before the first client waits for it, and the client answers',
    () async {
      // #196: example/no_plugin calls its channel at once in main(); the
      // client comes 400 ms later, as an IDE that polls for runners may.
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: noPluginAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final client = await RunnerClient.connect(endpoint);
      // A string, as the standard codec writes 'ok'.
      client.registerChannel(
        pigeonChannel,
        (_) async => Uint8List.fromList([7, 2, 0x6f, 0x6b]),
      );
      try {
        await client.frames.first.timeout(const Duration(seconds: 15));
        expect(
          output.where((line) => line.startsWith('NO_PLUGIN:')).single,
          startsWith('NO_PLUGIN:ok after'),
        );
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(noPluginAssets).existsSync()
            ? false
            : 'build the runner and example/no_plugin first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a plugin nobody serves before runApp gets no reply at once, and the '
    'client is told why the app stopped',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: noPluginAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final stderr = <String>[];
      runner.stderr.listen(stderr.add);
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        final failure = await client.startupFailures
            .firstWhere((failure) => failure != null)
            .timeout(const Duration(seconds: 15));
        expect(
          failure?.exception,
          'PlatformException(channel-error, Unable to establish connection '
          'on channel: "$pigeonChannel"., null, null)',
        );
        expect(failure?.stackTrace.first, startsWith('#0      main'));
        expect(failure?.channels, [pigeonChannel]);
        // The reply came back empty, and at once: nothing waited on a bound.
        final millis = replyMillis(client.startupLog, 'NO_PLUGIN:null');
        expect(millis, isNotNull, reason: client.startupLog.join('\n'));
        expect(millis, lessThan(1000));
        // The runner said so under its own name, for the tool's output.
        expect(
          client.startupLog.any(
            (line) => line.startsWith('🦝 nothing answered $pigeonChannel ('),
          ),
          isTrue,
        );
        expect(client.latestFrame, isNull);
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(noPluginAssets).existsSync()
            ? false
            : 'build the runner and example/no_plugin first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a plugin nobody serves after the first frame fails the call and the '
    'app goes on drawing',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: noPluginLateAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      runner.stderr.listen(output.add);
      final client = await RunnerClient.connect(endpoint);
      try {
        final failed = await client.frames
            .firstWhere((frame) => _pixel(frame, 400, 300) == orange)
            .timeout(const Duration(seconds: 15));
        expect(_pixel(failed, 5, 5), _blue);
        expect(client.startupFailure, isNull);
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (replyMillis(output, 'NO_PLUGIN_LATE:') == null &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          output.where((line) => line.contains('NO_PLUGIN_LATE:')).first,
          contains('NO_PLUGIN_LATE:MissingPluginException'),
        );
        expect(replyMillis(output, 'NO_PLUGIN_LATE:'), lessThan(1000));
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(noPluginLateAssets).existsSync()
            ? false
            : 'build the runner and example/no_plugin_late first',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a reply the client never sends is answered empty after the bound',
    () async {
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: noPluginLateAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      runner.stderr.listen(output.add);
      final client = await RunnerClient.connect(endpoint);
      // A client that takes the call and never answers.
      final asked = <DateTime>[];
      client.registerChannel(lateChannel, (data) {
        asked.add(DateTime.now());
        return Completer<Uint8List?>().future;
      });
      try {
        // The call at the first frame went out before or after the client
        // took the channel; either way it fails in the end.
        await client.frames
            .firstWhere((frame) => _pixel(frame, 400, 300) == orange)
            .timeout(const Duration(seconds: 20));
        for (final (phase, buttons) in [
          (PointerPhase.POINTER_PHASE_DOWN, 1),
          (PointerPhase.POINTER_PHASE_UP, 0),
        ]) {
          client.sendPointer(
            PointerEvent(
              phase: phase,
              x: 400,
              y: 300,
              buttons: Int64(buttons),
              device: PointerDevice.POINTER_DEVICE_MOUSE,
              pointerId: 1,
            ),
          );
        }
        await client.frames
            .firstWhere((frame) => _pixel(frame, 400, 300) == grey)
            .timeout(const Duration(seconds: 10));
        final tapped = DateTime.now();
        await client.frames
            .firstWhere((frame) => _pixel(frame, 400, 300) == orange)
            .timeout(const Duration(seconds: 15));
        final waited = DateTime.now().difference(tapped);
        final printed = DateTime.now().add(const Duration(seconds: 5));
        while (output.where((line) => line.contains('NO_PLUGIN_LATE:')).length <
                2 &&
            DateTime.now().isBefore(printed)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(asked, isNotEmpty);
        expect(waited, greaterThan(const Duration(seconds: 3)));
        expect(waited, lessThan(const Duration(seconds: 10)));
        expect(
          replyMillis(output, 'NO_PLUGIN_LATE:MissingPluginException'),
          greaterThanOrEqualTo(4000),
        );
        expect(
          output.where(
            (line) =>
                line ==
                '🦝 nothing answered $lateChannel (the client '
                    'did not answer in 5 s); the app sees no plugin',
          ),
          hasLength(1),
          reason: 'once per channel',
        );
        expect(client.startupFailure, isNull);
      } finally {
        client.shutdown();
        await client.close();
        expect(await _exitCode(runner), 0);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(noPluginLateAssets).existsSync()
            ? false
            : 'build the runner and example/no_plugin_late first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

/// A release of buffer [index] of [generation] as the GPU socket takes it,
/// framed, without a fence.
Uint8List _release(int generation, int index) {
  final payload =
      ByteData(16)
        ..setUint32(4, generation, Endian.little)
        ..setUint32(8, index, Endian.little)
        ..setUint32(12, 0, Endian.little);
  payload.buffer.asUint8List().setAll(0, 'RREL'.codeUnits);
  return MessageFraming.frame(payload.buffer.asUint8List());
}

/// The runner's exit code, waiting up to 10 s. One still running by then has
/// its threads sampled into the failure (macOS's `sample`) and is killed, so
/// a hang on CI says where it was.
Future<int?> _exitCode(RunnerProcess runner) async {
  try {
    return await runner.exitCode.timeout(const Duration(seconds: 10));
  } on TimeoutException {
    if (Platform.isMacOS) {
      final report = p.join(
        Directory.systemTemp.path,
        'runner-${runner.pid}.sample',
      );
      final sampled = await Process.run('sample', [
        '${runner.pid}',
        '2',
        '-file',
        report,
      ]);
      printOnFailure(
        'the runner did not exit; its threads:\n${sampled.stdout}',
      );
    }
    runner.kill();
    return null;
  }
}

/// A manifest entry for a plugin of [name] in [library]: registered by its
/// `<name>_plugin_register_with_registrar` on Linux, by [pluginClass] on
/// macOS, by `<pluginClass>RegisterWithRegistrar` on Windows.
Map<String, String> _pluginEntry(
  String name,
  String library,
  String pluginClass,
) => {
  'name': name,
  'library': library,
  if (Platform.isMacOS)
    'class': pluginClass
  else if (Platform.isWindows)
    'symbol': '${pluginClass}RegisterWithRegistrar'
  else
    'symbol': '${name}_plugin_register_with_registrar',
};

/// The SDK behind `FLUTTER_ROOT`, else behind the `flutter` on the PATH.
String? _sdkRoot(Map<String, String> environment) {
  if (environment['FLUTTER_ROOT'] case final root? when root.isNotEmpty) {
    return root;
  }
  return RuntimeStore.sdkRootOnPath();
}

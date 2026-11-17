// What the runner's integration tests (test/integration/) share: where the
// runner and its inputs are, and the helpers more than one file uses. Each
// file takes what it needs; nothing here is state, so the files can run side
// by side, each test in its own temporary directory (#413).

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:raccoon/raccoon.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

// The colours the example apps draw.
const blue = (r: 0x1E, g: 0x88, b: 0xE5);
const red = (r: 0xE5, g: 0x39, b: 0x35);
const green = (r: 0x43, g: 0xA0, b: 0x47);
const orange = (r: 0xFB, g: 0x8C, b: 0x00);
const white = (r: 0xFF, g: 0xFF, b: 0xFF);

/// example/camera's picture line: the verdict on the test pattern's bars,
/// the colours seen where they are, and the picture's path.
final pictureLine = RegExp(r'^picture (bars \w+) left=(\S+) right=(\S+) (.*)$');

/// The colour at ([x], [y]), whichever byte order the host rasters in.
({int r, int g, int b}) pixel(Frame frame, int x, int y) {
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

String? _firstExisting(Iterable<String> candidates) =>
    candidates.where((c) => c.isNotEmpty && File(c).existsSync()).firstOrNull;

/// The runner, its engine and ICU data, and the example bundles, found from
/// the package directory and the environment once per test file.
final class RunnerFixture {
  factory RunnerFixture() {
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
    final viewsAssets = p.join(
      runnerDir,
      'example',
      'views',
      'build',
      'flutter_assets',
    );
    // example/channels calls desktop_window, window_manager, window_size and
    // shared_preferences_foundation at startup and shows a green box only when
    // every answer was right.
    final channelsAssets = p.join(
      runnerDir,
      'example',
      'channels',
      'build',
      'flutter_assets',
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
    // example/plugins_modal animates, then asks the echo plugin for a message
    // box that closes itself after two seconds.
    final pluginsModalAssets = p.join(
      p.dirname(p.dirname(p.dirname(assets))),
      'plugins_modal',
      'build',
      'flutter_assets',
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
    return RunnerFixture._(
      workspace: workspace,
      runnerDir: runnerDir,
      environment: environment,
      binary: binary,
      assets: assets,
      sdk: sdk,
      revision: revision,
      engineDir: engineDir,
      icu: icu,
      ready: ready,
      viewsAssets: viewsAssets,
      channelsAssets: channelsAssets,
      cameraAssets: cameraAssets,
      testVideo: testVideo,
      pluginLibrary: pluginLibrary,
      flutterFramework: flutterFramework,
      pluginsAppAssets: pluginsAppAssets,
      pluginsModalAssets: pluginsModalAssets,
      noPluginAssets: noPluginAssets,
      noPluginLateAssets: noPluginLateAssets,
    );
  }

  RunnerFixture._({
    required this.workspace,
    required this.runnerDir,
    required this.environment,
    required this.binary,
    required this.assets,
    required this.sdk,
    required this.revision,
    required this.engineDir,
    required this.icu,
    required this.ready,
    required this.viewsAssets,
    required this.channelsAssets,
    required this.cameraAssets,
    required this.testVideo,
    required this.pluginLibrary,
    required this.flutterFramework,
    required this.pluginsAppAssets,
    required this.pluginsModalAssets,
    required this.noPluginAssets,
    required this.noPluginLateAssets,
  });

  final String workspace;
  final String runnerDir;
  final Map<String, String> environment;
  final String? binary;
  final String assets;
  final String? sdk;
  final String? revision;
  final String? engineDir;
  final String? icu;
  final bool ready;
  final String viewsAssets;
  final String channelsAssets;
  final String cameraAssets;
  final String testVideo;
  final String pluginLibrary;
  final String? flutterFramework;
  final String pluginsAppAssets;
  final String pluginsModalAssets;
  final String noPluginAssets;
  final String noPluginLateAssets;
}

// The Pigeon channel example/no_plugin calls before runApp, which nobody
// serves.
const pigeonChannel =
    'dev.flutter.pigeon.absent_plugin.AbsentHostApi.initialize';

/// How long the app took for its call, from what it printed last with
/// [prefix], such as `NO_PLUGIN:null after 3 ms`.
int? replyMillis(Iterable<String> lines, String prefix) {
  final printed = lines.where((line) => line.contains(prefix)).lastOrNull;
  if (printed == null) return null;
  final match = RegExp(r'after (\d+) ms').firstMatch(printed);
  return int.tryParse(match?.group(1) ?? '');
}

/// Fails the test, as `expect(await runnerExitCode(runner), 0)` would, when
/// [runner] doesn't exit with 0, but without throwing: from a test's
/// `finally`, that throw took the place of whatever failed first, which
/// the failure then never showed (#309, #318).
Future<void> expectExit(RunnerProcess runner, {String? reason}) async {
  final code = await runnerExitCode(runner);
  if (code != 0) {
    registerException(
      TestFailure(
        'the runner exited with $code, not 0${reason == null ? '' : ': $reason'}',
      ),
      StackTrace.current,
    );
  }
}

/// The runner's exit code, waiting up to 10 s. One still running by then has
/// its threads sampled into the failure (macOS's `sample`) and is killed, so
/// a hang on CI says where it was.
Future<int?> runnerExitCode(RunnerProcess runner) async {
  try {
    return await runner.exitCode.timeout(const Duration(seconds: 10));
  } on TimeoutException {
    if (Platform.isMacOS) {
      final report = p.join(
        Directory.systemTemp.path,
        'runner-${runner.pid}.sample',
      );
      await Process.run('sample', ['${runner.pid}', '2', '-file', report]);
      // The report is in the file: sample says only where it put it.
      final threads = switch (File(report)) {
        final file when file.existsSync() => file
            .readAsLinesSync()
            .skipWhile((line) => !line.startsWith('Call graph:'))
            .take(150)
            .join('\n'),
        _ => 'no sample',
      };
      printOnFailure(
        'the runner did not exit; its threads ($report):\n$threads',
      );
    }
    if (runner.lastLines case final lines when lines.isNotEmpty) {
      printOnFailure('its last lines:\n${lines.join('\n')}');
    }
    runner.kill();
    return null;
  }
}

/// A manifest entry for a plugin of [name] in [library]: registered by its
/// `<name>_plugin_register_with_registrar` on Linux, by [pluginClass] on
/// macOS, by `<pluginClass>RegisterWithRegistrar` on Windows.
Map<String, String> pluginEntry(
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

/// Runs the device helper with [arguments]: on Windows through Git Bash, as
/// Flutter's custom device entry does, its paths with forward slashes. With
/// [asGiven], the arguments go as they are (a name with a backslash).
Future<ProcessResult> runHelper(
  String runnerDir,
  List<String> arguments,
  Map<String, String> environment, {
  bool asGiven = false,
}) {
  String posix(String value) => value.replaceAll(r'\', '/');
  final helper = p.join(runnerDir, 'tool', 'raccoon-device');
  final launcher = CustomDeviceConfig.hostLauncher;
  return Process.run(
    launcher.firstOrNull ?? helper,
    [
      if (launcher.isNotEmpty) posix(helper),
      ...asGiven ? arguments : arguments.map(posix),
    ],
    environment: {
      for (final MapEntry(:key, :value) in environment.entries)
        key: posix(value),
    },
  );
}

import 'package:raccoon/raccoon.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

/// What the runner relays when main() dies of a Pigeon call nobody serves,
/// as the engine and the runner print it.
const _pigeon =
    'dev.flutter.pigeon.firebase_core_platform_interface.FirebaseCoreHostApi'
    '.initializeCore';
const _log = [
  'The Dart VM service is listening on http://127.0.0.1:4000/abc=/',
  'raccoon_runner: nothing answered $_pigeon (no client); the app sees no '
      'plugin',
  '[ERROR:flutter/runtime/dart_vm_initializer.cc(40)] Unhandled Exception: '
      'PlatformException(channel-error, Unable to establish connection on '
      'channel: "$_pigeon"., null, null)',
  '#0      FirebaseCoreHostApi.initializeCore (package:firebase_core/x.dart:1:2)',
  '<asynchronous suspension>',
  '#1      main (package:app/main.dart:5:3)',
  '<asynchronous suspension>',
  '',
];

Plugins _report(List<(String, PluginState, String)> plugins) => Plugins(
  plugins: [
    for (final (name, state, detail) in plugins)
      PluginReport(name: name, state: state, detail: detail),
  ],
);

void main() {
  test('reads the exception main() died of and the channel behind it', () {
    final failure = StartupFailure.fromLog(_log);

    expect(
      failure?.exception,
      'PlatformException(channel-error, Unable to establish connection on '
      'channel: "$_pigeon"., null, null)',
    );
    expect(failure?.stackTrace, hasLength(4));
    expect(failure?.stackTrace.first, startsWith('#0'));
    expect(failure?.channels, [_pigeon]);
    expect(failure?.plugins, isEmpty);
  });

  test('names the plugin when the report says it has no host', () {
    final failure = StartupFailure.fromLog(
      _log,
      plugins: _report([
        ('firebase', PluginState.PLUGIN_STATE_NO_HOST, ''),
        (
          'firebase_core',
          PluginState.PLUGIN_STATE_NO_HOST,
          'no Linux implementation',
        ),
        ('url_launcher', PluginState.PLUGIN_STATE_LOADED, ''),
      ]),
    );

    expect(failure?.hints, ['firebase_core has no Linux implementation']);
  });

  test('a plugin that works is no hint, even when its name matches', () {
    final failure = StartupFailure.fromLog(
      _log,
      plugins: _report([
        ('firebase_core', PluginState.PLUGIN_STATE_LOADED, ''),
      ]),
    );

    expect(failure?.hints, isEmpty);
  });

  test('reads the Dart VM\'s own form, the exception on the next line', () {
    final failure = StartupFailure.fromLog([
      'Unhandled exception:',
      'MissingPluginException(No implementation found for method x)',
      '#0      main (file:///app/main.dart:3:1)',
    ]);

    expect(
      failure?.exception,
      'MissingPluginException(No implementation found for method x)',
    );
    expect(failure?.stackTrace, ['#0      main (file:///app/main.dart:3:1)']);
  });

  test('a channel nothing answered is a failure without an exception', () {
    final failure = StartupFailure.fromLog([
      'raccoon_runner: nothing answered plugins.flutter.io/camera (the client '
          'has no handler); the app sees no plugin',
      'raccoon_runner: nothing answered plugins.flutter.io/camera (the client '
          'did not answer in 5 s); the app sees no plugin',
    ]);

    expect(failure?.exception, isNull);
    expect(failure?.channels, ['plugins.flutter.io/camera']);
  });

  test('the runner\'s 🦝 lines read as its old ones did', () {
    final failure = StartupFailure.fromLog([
      '🦝 nothing answered plugins.flutter.io/camera (no client); the app '
          'sees no plugin',
    ]);

    expect(failure?.channels, ['plugins.flutter.io/camera']);
  });

  test('an app the engine would not start: why, and what fixes it (#408)', () {
    const kernel =
        '[ERROR:flutter/shell/common/shell.cc(119)] Dart Error: Can\'t load '
        'Kernel binary: Invalid kernel binary format version (expected 141, '
        'found 138).';
    const said =
        '🦝 the app did not start: built with another Flutter (Invalid kernel '
        'binary format version (expected 141, found 138)); flutter run -d '
        'raccoon builds it again';
    final failure = StartupFailure.fromLog([
      'The Dart VM service is listening on http://127.0.0.1:4000/abc=/',
      kernel,
      '[ERROR:flutter/shell/common/shell.cc(808)] Could not launch engine '
          'with configuration.',
      said,
      '🦝 stopped',
    ]);

    expect(
      failure?.exception,
      'Built with another Flutter (Invalid kernel binary format version '
      '(expected 141, found 138))',
    );
    expect(failure?.hints, ['flutter run -d raccoon builds it again']);
    expect(failure?.stackTrace, isEmpty);
    expect(failure?.channels, isEmpty);
    expect(StartupFailure.tells(said), isTrue);
    expect(StartupFailure.tells(kernel), isFalse);
    // With no fix to give, the reason alone.
    expect(
      StartupFailure.fromLog([
        '🦝 the app did not start: the engine could not launch it',
      ])?.hints,
      isEmpty,
    );
  });

  test('only failure lines and stack lines can change what the log says', () {
    expect(StartupFailure.tells(_log[0]), isFalse); // the VM service
    expect(StartupFailure.tells(_log[1]), isTrue); // nothing answered
    expect(StartupFailure.tells(_log[2]), isTrue); // unhandled exception
    expect(StartupFailure.tells(_log[3]), isTrue); // a stack line
    expect(StartupFailure.tells('<asynchronous suspension>'), isTrue);
    expect(StartupFailure.tells('flutter: loading 3 of 9'), isFalse);
  });

  test('a bare exception marker leaves the text to the next line', () {
    expect(StartupFailure.leavesTextToNext('Unhandled exception:'), isTrue);
    expect(StartupFailure.leavesTextToNext(_log[2]), isFalse);
    expect(StartupFailure.leavesTextToNext('Bad state: boom'), isFalse);
  });

  test('a log that tells of nothing gone wrong is no failure', () {
    expect(
      StartupFailure.fromLog([
        'raccoon_runner: client connected',
        'flutter: hello',
      ]),
      isNull,
    );
  });

  test('maps channels to plugins by a segment of their name', () {
    final reports =
        _report([
          ('geolocator', PluginState.PLUGIN_STATE_NO_HOST, ''),
          ('camera', PluginState.PLUGIN_STATE_FAILED, 'did not build'),
          ('path', PluginState.PLUGIN_STATE_NO_HOST, ''),
        ]).plugins;

    expect(
      StartupFailure.pluginOf('flutter.baseflow.com/geolocator', reports)?.name,
      'geolocator',
    );
    expect(
      StartupFailure.pluginOf(
        'plugins.flutter.io/camera_android',
        reports,
      )?.name,
      'camera',
    );
    expect(
      StartupFailure.pluginOf('plugins.flutter.io/path_provider', reports),
      isNull,
      reason: 'path_provider is not path',
    );
    expect(StartupFailure.pluginOf('cameraman', reports), isNull);
  });

  test('a channel two plugins match goes to the longer name', () {
    final reports =
        _report([
          ('firebase_auth', PluginState.PLUGIN_STATE_NO_HOST, ''),
          ('firebase_auth_web', PluginState.PLUGIN_STATE_FAILED, ''),
        ]).plugins;

    expect(
      StartupFailure.pluginOf(
        'plugins.flutter.io/firebase_auth_web',
        reports,
      )?.name,
      'firebase_auth_web',
    );
    expect(
      StartupFailure.pluginOf(
        'plugins.flutter.io/firebase_auth_web',
        reports.reversed,
      )?.name,
      'firebase_auth_web',
    );
  });

  // raccoon#16: four of the most used plugins with no Linux implementation
  // name their channels after what they do, not the package.
  test('maps a channel named after what the plugin does', () {
    final reports =
        _report([
          ('permission_handler', PluginState.PLUGIN_STATE_NO_HOST, ''),
          ('google_maps_flutter', PluginState.PLUGIN_STATE_NO_HOST, ''),
          ('flutter_stripe', PluginState.PLUGIN_STATE_NO_HOST, ''),
          ('sensors_plus', PluginState.PLUGIN_STATE_NO_HOST, ''),
          ('firebase_core', PluginState.PLUGIN_STATE_NO_HOST, ''),
        ]).plugins;
    String? of(String channel) =>
        StartupFailure.pluginOf(channel, reports)?.name;

    expect(
      of('flutter.baseflow.com/permissions/methods'),
      'permission_handler',
    );
    expect(of('plugins.flutter.io/google_maps_1'), 'google_maps_flutter');
    expect(of('flutter.stripe/payments'), 'flutter_stripe');
    expect(of('dev.fluttercommunity.plus/sensors/method'), 'sensors_plus');
    expect(of('plugins.flutter.io/firebase_core'), 'firebase_core');
    expect(of('plugins.flutter.io/permission'), 'permission_handler');
    expect(of('plugins.flutter.io/maps'), isNull);
  });

  test('a whole name beats a stem', () {
    final reports =
        _report([
          ('sensors_plus', PluginState.PLUGIN_STATE_NO_HOST, ''),
          ('sensors', PluginState.PLUGIN_STATE_FAILED, ''),
        ]).plugins;

    expect(
      StartupFailure.pluginOf('plugins.flutter.io/sensors', reports)?.name,
      'sensors',
    );
    expect(StartupFailure.stemOf('sensors_plus'), 'sensors');
    expect(StartupFailure.stemOf('flutter_tts'), isNull, reason: 'too short');
    expect(StartupFailure.stemOf('camera'), isNull, reason: 'nothing off');
  });

  test('says what became of a plugin in a line', () {
    String hint(PluginState state, String detail) => StartupFailure.hintFor(
      PluginReport(name: 'camera', state: state, detail: detail),
    );

    expect(
      hint(PluginState.PLUGIN_STATE_NO_HOST, ''),
      'camera has no implementation for this host',
    );
    expect(
      hint(PluginState.PLUGIN_STATE_FAILED, 'did not build'),
      'camera did not load: did not build',
    );
    expect(
      hint(PluginState.PLUGIN_STATE_BUILT_NOTHING, ''),
      'camera built and made no library',
    );
    // An install told to take only what is cached (#214).
    expect(
      hint(
        PluginState.PLUGIN_STATE_SKIPPED,
        'not built: native plugins are cached only (RACCOON_PLUGINS=cached)',
      ),
      'camera: not built: native plugins are cached only '
      '(RACCOON_PLUGINS=cached)',
    );
  });

  test('a channel of a skipped plugin is put down to it', () {
    final reports = [
      PluginReport(
        name: 'url_launcher_macos',
        state: PluginState.PLUGIN_STATE_SKIPPED,
      ),
    ];
    expect(
      StartupFailure.pluginOf(
        'dev.flutter.pigeon.url_launcher_macos.UrlLauncherApi.launchUrl',
        reports,
      )?.name,
      'url_launcher_macos',
    );
  });

  // raccoon#394: a plugin that wants the view is reported under its Linux
  // package's name (#386), its channel carries the app-facing one.
  test('a host\'s own package matches a channel without its suffix', () {
    final reports =
        _report([
          (
            'yaru_window_linux',
            PluginState.PLUGIN_STATE_NO_HOST,
            "no implementation on Raccoon: it wants the view's GTK window, "
                'and there is no view yet (#365)',
          ),
          ('desktop_drop_windows', PluginState.PLUGIN_STATE_FAILED, ''),
          ('url_launcher_macos', PluginState.PLUGIN_STATE_SKIPPED, ''),
          ('window_size', PluginState.PLUGIN_STATE_NO_HOST, ''),
        ]).plugins;
    String? of(String channel) =>
        StartupFailure.pluginOf(channel, reports)?.name;

    expect(of('yaru_window'), 'yaru_window_linux');
    expect(of('desktop_drop'), 'desktop_drop_windows');
    expect(of('plugins.flutter.io/url_launcher'), 'url_launcher_macos');
    // Still a whole segment, never part of one.
    expect(of('yaru'), isNull);
    expect(of('yaru_window_plus'), isNull);
    expect(of('yaru/window'), isNull);
    expect(
      StartupFailure.pluginOf('yaru_window', [
        for (final report in reports)
          if (report.name == 'window_size') report,
      ]),
      isNull,
      reason: 'window_size is not yaru_window',
    );
  });

  test('a channel a plugin and its host package match goes to the longer', () {
    final reports =
        _report([
          ('yaru_window', PluginState.PLUGIN_STATE_FAILED, ''),
          ('yaru_window_linux', PluginState.PLUGIN_STATE_NO_HOST, ''),
        ]).plugins;

    expect(
      StartupFailure.pluginOf('yaru_window', reports)?.name,
      'yaru_window_linux',
    );
    expect(
      StartupFailure.pluginOf('yaru_window', reports.reversed)?.name,
      'yaru_window_linux',
    );
  });

  test('an app stopped on yaru_window is told of yaru_window_linux', () {
    final failure = StartupFailure.fromLog(
      [
        '🦝 nothing answered yaru_window (no plugin); the app sees no plugin',
        '[ERROR:flutter/runtime/dart_vm_initializer.cc(40)] Unhandled '
            'Exception: MissingPluginException(No implementation found for '
            'method state on channel yaru_window)',
        '#0      MethodChannel._invokeMethod (package:flutter/x.dart:1:2)',
      ],
      plugins: _report([
        (
          'yaru_window_linux',
          PluginState.PLUGIN_STATE_NO_HOST,
          "no implementation on Raccoon: it wants the view's GTK window, "
              'and there is no view yet (#365)',
        ),
      ]),
    );

    expect(failure?.channels, ['yaru_window']);
    expect(failure?.hints, [
      'yaru_window_linux has no implementation on Raccoon: it wants the '
          "view's GTK window, and there is no view yet (#365)",
    ]);
  });

  test('the device the entry asks for, unanswered, is no failure', () {
    // raccoon#235: a client with no profile answers nothing there, which
    // is the host, and an app slow to its first frame was reported failing.
    expect(
      StartupFailure.fromLog([
        '🦝 nothing answered raccoon/device (the client has no handler); '
            'the app sees no plugin',
      ]),
      isNull,
    );
  });
}

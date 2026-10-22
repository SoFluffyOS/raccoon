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
  });
}

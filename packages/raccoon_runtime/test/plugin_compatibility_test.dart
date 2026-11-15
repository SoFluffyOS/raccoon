import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

const _sample = '''
{
  "plugins": {
    "android": [
      {"name": "camera_android", "native_build": true},
      {"name": "path_provider_android", "native_build": true}
    ],
    "linux": [
      {"name": "path_provider_linux", "native_build": false},
      {"name": "url_launcher_linux", "native_build": true},
      {"name": "file_selector_linux", "native_build": true},
      {"name": "window_manager", "native_build": true}
    ],
    "macos": [
      {"name": "path_provider_foundation", "native_build": true},
      {"name": "shared_preferences_foundation", "native_build": true},
      {"name": "url_launcher_macos", "native_build": true},
      {"name": "window_manager", "native_build": true}
    ],
    "windows": [
      {"name": "url_launcher_windows", "native_build": true}
    ]
  }
}
''';

void main() {
  test('classifies plugins by their implementation for the host', () {
    final compatibility = PluginCompatibility(
      servedByRaccoon: {'file_selector_linux'},
      platform: 'linux',
    );

    final report = {
      for (final status in compatibility.parse(_sample))
        status.name: status.support,
    };

    expect(report, {
      'camera_android': PluginSupport.notForThisPlatform,
      'file_selector_linux': PluginSupport.servedByRaccoon,
      'path_provider_android': PluginSupport.notForThisPlatform,
      'path_provider_foundation': PluginSupport.notForThisPlatform,
      'path_provider_linux': PluginSupport.works,
      'shared_preferences_foundation': PluginSupport.notForThisPlatform,
      'url_launcher_linux': PluginSupport.native,
      'url_launcher_macos': PluginSupport.notForThisPlatform,
      'url_launcher_windows': PluginSupport.notForThisPlatform,
      'window_manager': PluginSupport.native,
    });
  });

  // Native plugins are built and loaded on every host; the window plugins
  // are the runner's own (raccoon#16).
  test('loads native plugins and serves the window plugins on Linux', () {
    final report = {
      for (final status in PluginCompatibility(
        platform: 'linux',
      ).parse(_sample))
        status.name: status.support,
    };

    expect(report['url_launcher_linux'], PluginSupport.native);
    expect(report['file_selector_linux'], PluginSupport.native);
    expect(report['window_manager'], PluginSupport.servedByRaccoon);
    expect(report['path_provider_linux'], PluginSupport.works);
  });

  test('reads the macOS list on a Mac', () {
    final report = {
      for (final status in PluginCompatibility(
        platform: 'macos',
      ).parse(_sample))
        status.name: status.support,
    };

    expect(report['url_launcher_macos'], PluginSupport.native);
    expect(report['path_provider_foundation'], PluginSupport.native);
    expect(
      report['shared_preferences_foundation'],
      PluginSupport.servedByRaccoon,
    );
    expect(report['window_manager'], PluginSupport.servedByRaccoon);
    expect(report['url_launcher_linux'], PluginSupport.notForThisPlatform);
  });

  test('serves shared_preferences_foundation only on a Mac', () {
    expect(
      PluginCompatibility.servedOn('macos'),
      contains('shared_preferences_foundation'),
    );
    expect(
      PluginCompatibility.servedOn('linux'),
      isNot(contains('shared_preferences_foundation')),
    );
    expect(
      PluginCompatibility.servedOn('windows'),
      PluginCompatibility.defaultServedByRaccoon,
    );
  });

  test('names the host the way the tool does', () {
    expect(PluginCompatibility.platformFor('macos'), 'macos');
    expect(
      () => PluginCompatibility.platformFor('ios'),
      throwsUnsupportedError,
    );
  });

  test('tolerates a project without the file', () {
    expect(PluginCompatibility().forProject('/nowhere'), isEmpty);
  });

  // #134: the tool truncates the file before it writes it again.
  test('reads a file cut short, or of another shape, as no report', () {
    final temp = Directory.systemTemp.createTempSync('raccoon_plugins');
    addTearDown(() => temp.deleteSync(recursive: true));
    final compatibility = PluginCompatibility(platform: 'linux');
    final file = File(p.join(temp.path, PluginCompatibility.fileName));
    for (final text in [
      '',
      '{"plugins": {"linux": [',
      '{"plugins": {"linux": 3}}',
    ]) {
      file.writeAsStringSync(text);
      expect(compatibility.forProject(temp.path), isEmpty, reason: text);
    }
    // #307: cut inside a character, as in "My Wörk": the ö's first byte.
    file.writeAsBytesSync([
      ...'{"plugins": {"linux": [{"path": "/My W'.codeUnits,
      0xc3,
    ]);
    expect(compatibility.forProject(temp.path), isEmpty);
  });
}

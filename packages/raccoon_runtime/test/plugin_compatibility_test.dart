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
      {"name": "file_selector_linux", "native_build": true}
    ],
    "macos": [
      {"name": "path_provider_foundation", "native_build": true},
      {"name": "url_launcher_macos", "native_build": true}
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
      servedByRaccoon: {'url_launcher_linux'},
      platform: 'linux',
    );

    final report = {
      for (final status in compatibility.parse(_sample))
        status.name: status.support,
    };

    expect(report, {
      'camera_android': PluginSupport.notForThisPlatform,
      'file_selector_linux': PluginSupport.unavailable,
      'path_provider_android': PluginSupport.notForThisPlatform,
      'path_provider_foundation': PluginSupport.notForThisPlatform,
      'path_provider_linux': PluginSupport.works,
      'url_launcher_linux': PluginSupport.servedByRaccoon,
      'url_launcher_macos': PluginSupport.notForThisPlatform,
      'url_launcher_windows': PluginSupport.notForThisPlatform,
    });
  });

  test('reads the macOS list on a Mac', () {
    final report = {
      for (final status in PluginCompatibility(
        platform: 'macos',
      ).parse(_sample))
        status.name: status.support,
    };

    expect(report['url_launcher_macos'], PluginSupport.servedByRaccoon);
    expect(report['path_provider_foundation'], PluginSupport.unavailable);
    expect(report['url_launcher_linux'], PluginSupport.notForThisPlatform);
  });

  test('serves url_launcher by default on every desktop', () {
    for (final (platform, plugin) in [
      ('linux', 'url_launcher_linux'),
      ('macos', 'url_launcher_macos'),
      ('windows', 'url_launcher_windows'),
    ]) {
      final report = PluginCompatibility(platform: platform).parse(_sample);
      expect(
        report.singleWhere((s) => s.name == plugin).support,
        PluginSupport.servedByRaccoon,
      );
    }
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
}

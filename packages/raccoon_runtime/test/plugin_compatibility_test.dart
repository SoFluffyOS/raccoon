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
    ]
  }
}
''';

void main() {
  test('classifies plugins by their linux implementation', () {
    const compatibility = PluginCompatibility(
      servedByRaccoon: {'url_launcher_linux'},
    );

    final report = {
      for (final status in compatibility.parse(_sample))
        status.name: status.support,
    };

    expect(report, {
      'camera_android': PluginSupport.notForThisPlatform,
      'file_selector_linux': PluginSupport.unavailable,
      'path_provider_android': PluginSupport.notForThisPlatform,
      'path_provider_linux': PluginSupport.works,
      'url_launcher_linux': PluginSupport.servedByRaccoon,
    });
  });

  test('serves url_launcher by default', () {
    final report = const PluginCompatibility().parse(_sample);

    expect(
      report.singleWhere((s) => s.name == 'url_launcher_linux').support,
      PluginSupport.servedByRaccoon,
    );
  });

  test('tolerates a project without the file', () {
    expect(const PluginCompatibility().forProject('/nowhere'), isEmpty);
  });
}

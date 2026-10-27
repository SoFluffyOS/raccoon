import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('the setting lives beside the size, where the helper reads it', () {
    expect(
      AppPlugins.forHost({'XDG_DATA_HOME': '/data'}).directory,
      AppSizes.forHost({'XDG_DATA_HOME': '/data'}).directory,
    );
  });

  test('a saved setting reads back; build, the default, leaves no file', () {
    final temp = Directory.systemTemp.createTempSync('raccoon_plugins');
    addTearDown(() => temp.deleteSync(recursive: true));
    final plugins = AppPlugins(temp.path);
    final file = File(p.join(temp.path, 'wonders', 'plugins'));
    expect(plugins.read('wonders'), NativePlugins.build);

    plugins.save('wonders', NativePlugins.cached);
    expect(file.readAsStringSync(), 'cached\n');
    expect(plugins.read('wonders'), NativePlugins.cached);

    plugins.save('wonders', NativePlugins.build);
    expect(file.existsSync(), isFalse);
    expect(plugins.read('wonders'), NativePlugins.build);

    file
      ..createSync(recursive: true)
      ..writeAsStringSync('sometimes\n');
    expect(plugins.read('wonders'), NativePlugins.build);
  });
}

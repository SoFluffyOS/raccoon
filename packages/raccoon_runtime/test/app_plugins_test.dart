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

  test('an app\'s own setting wins over the host\'s default', () {
    final temp = Directory.systemTemp.createTempSync('raccoon_plugins');
    addTearDown(() => temp.deleteSync(recursive: true));
    final plugins = AppPlugins(temp.path);
    final file = File(p.join(temp.path, 'wonders', 'plugins'));
    expect(plugins.read('wonders'), NativePlugins.build);

    plugins.saveDefault(NativePlugins.off);
    expect(File(p.join(temp.path, '.plugins')).readAsStringSync(), 'off\n');
    expect(plugins.read('wonders'), NativePlugins.off);

    plugins.save('wonders', NativePlugins.build);
    expect(file.readAsStringSync(), 'build\n');
    expect(plugins.read('wonders'), NativePlugins.build);
    expect(plugins.read('cookbook'), NativePlugins.off);

    plugins.saveDefault(NativePlugins.build);
    expect(File(p.join(temp.path, '.plugins')).existsSync(), isFalse);
    expect(plugins.readDefault(), NativePlugins.build);

    file.writeAsStringSync('sometimes\n');
    expect(plugins.read('wonders'), NativePlugins.build);
    expect(plugins.readOwn('wonders'), isNull);
  });

  test('an app that clears its own setting follows the default', () {
    final temp = Directory.systemTemp.createTempSync('raccoon_plugins');
    addTearDown(() => temp.deleteSync(recursive: true));
    final plugins =
        AppPlugins(temp.path)
          ..saveDefault(NativePlugins.cached)
          ..save('wonders', NativePlugins.build);
    expect(plugins.readOwn('wonders'), NativePlugins.build);
    plugins.clear('wonders');
    expect(plugins.readOwn('wonders'), isNull);
    expect(plugins.read('wonders'), NativePlugins.cached);
  });
}

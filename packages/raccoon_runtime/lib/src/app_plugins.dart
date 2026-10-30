import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/src/app_sizes.dart';

/// What an install does with an app's native plugins (#214).
enum NativePlugins {
  /// Builds what isn't cached: every plugin that builds loads.
  build,

  /// Takes the cache and the release's prebuilt plugins, and compiles
  /// nothing: the rest are skipped.
  cached,

  /// None at all.
  off,
}

/// Each app's [NativePlugins], where `raccoon-device install` finds it when
/// `RACCOON_PLUGINS` says nothing: `<data>/raccoon/data/<app>/plugins`,
/// beside its size, or else the host's default, `<data>/raccoon/data/.plugins`.
/// Every instance of an app (`wonders`, `wonders@tablet`) shares its
/// project's, so [app] is the project's name.
final class AppPlugins {
  const AppPlugins(this.directory);

  /// The helper's data directory, as [AppSizes.forHost] finds it.
  factory AppPlugins.forHost(Map<String, String> environment) =>
      AppPlugins(AppSizes.forHost(environment).directory);

  /// The directory the setting files sit under, a folder per app.
  final String directory;

  File _file(String app) => File(p.join(directory, app, 'plugins'));

  // Hidden: no Dart package, so no app, is named with a dot.
  File get _defaultFile => File(p.join(directory, '.plugins'));

  /// [app]'s setting: its own, else the host's [readDefault].
  NativePlugins read(String app) => _parse(_file(app)) ?? readDefault();

  /// [app]'s own setting; null when it follows the host's default.
  NativePlugins? readOwn(String app) => _parse(_file(app));

  /// [app] follows the host's default again.
  void clear(String app) {
    final file = _file(app);
    if (file.existsSync()) file.deleteSync();
  }

  /// The host's setting for an app with none of its own:
  /// [NativePlugins.build] unless one was saved.
  NativePlugins readDefault() => _parse(_defaultFile) ?? NativePlugins.build;

  /// Saves [plugins] for [app]'s next install, over the host's default.
  void save(String app, NativePlugins plugins) => _write(_file(app), plugins);

  /// Saves the host's default; [NativePlugins.build], the helper's own,
  /// leaves no file.
  void saveDefault(NativePlugins plugins) {
    if (plugins != NativePlugins.build) {
      _write(_defaultFile, plugins);
      return;
    }
    if (_defaultFile.existsSync()) _defaultFile.deleteSync();
  }

  static NativePlugins? _parse(File file) {
    if (!file.existsSync()) return null;
    try {
      return NativePlugins.values.asNameMap()[file.readAsStringSync().trim()];
    } on FileSystemException {
      return null;
    }
  }

  static void _write(File file, NativePlugins plugins) =>
      file
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('${plugins.name}\n');
}

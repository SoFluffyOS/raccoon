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
/// beside its size. Every instance of an app (`wonders`, `wonders@tablet`)
/// shares its project's, so [app] is the project's name.
final class AppPlugins {
  const AppPlugins(this.directory);

  /// The helper's data directory, as [AppSizes.forHost] finds it.
  factory AppPlugins.forHost(Map<String, String> environment) =>
      AppPlugins(AppSizes.forHost(environment).directory);

  /// The directory the setting files sit under, a folder per app.
  final String directory;

  File _file(String app) => File(p.join(directory, app, 'plugins'));

  /// [app]'s setting: [NativePlugins.build] unless one was saved.
  NativePlugins read(String app) {
    final file = _file(app);
    if (!file.existsSync()) return NativePlugins.build;
    final saved = file.readAsStringSync().trim();
    return NativePlugins.values.asNameMap()[saved] ?? NativePlugins.build;
  }

  /// Saves [plugins] for [app]'s next install; [NativePlugins.build], the
  /// default, leaves no file.
  void save(String app, NativePlugins plugins) {
    final file = _file(app);
    if (plugins == NativePlugins.build) {
      if (file.existsSync()) file.deleteSync();
      return;
    }
    file
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('${plugins.name}\n');
  }
}

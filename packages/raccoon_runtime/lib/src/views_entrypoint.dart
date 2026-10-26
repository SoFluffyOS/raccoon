import 'package:raccoon_runtime/src/raccoon_entrypoint.dart';

/// The entry point a views run starts an app with (#182). `runApp` draws
/// into the app's first view only; this one installs a binding that lays
/// the app's root widget out in every view the runner gives it, a new
/// instance in each, then calls the app's own `main`. It is
/// [RaccoonEntrypoint]'s with `views`, so each view shows its device too.
///
/// What each view shares is the app's: statics and singletons are one,
/// navigation and widget state are per view. A root that holds a global
/// key (a navigator key the app keeps) can't be in two views at once, and
/// an app that installs a binding of its own finds this one there first.
abstract final class ViewsEntrypoint {
  /// Where [write] puts the entry point, relative to the project.
  static final path = RaccoonEntrypoint.viewsPath;

  /// Writes the entry point for the project at [projectDirectory], whose
  /// main library is [target] (relative to it), and returns its path. Null
  /// when [target] is not under `lib/` or the pubspec names no package.
  static String? write(
    String projectDirectory, {
    String target = 'lib/main.dart',
  }) => RaccoonEntrypoint.write(projectDirectory, target: target, views: true);

  /// The package the pubspec in [projectDirectory] names, or null.
  static String? packageOf(String projectDirectory) =>
      RaccoonEntrypoint.packageOf(projectDirectory);

  /// The entry point's source, importing the app's main from [mainImport].
  static String sourceFor(String mainImport) =>
      RaccoonEntrypoint.sourceFor(mainImport, views: true);
}

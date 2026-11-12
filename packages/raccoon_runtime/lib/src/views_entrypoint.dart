import 'dart:convert';
import 'dart:typed_data';

import 'package:raccoon_runtime/src/raccoon_entrypoint.dart';

/// The entry point a views run starts an app with (#182). `runApp` draws
/// into the app's first view only; this one installs a binding that lays
/// the app's root widget out in every view the runner gives it, a new
/// instance in each, then calls the app's own `main`. It is
/// [RaccoonEntrypoint]'s with `views`, so each view shows its device too.
///
/// What each view shares is the app's: statics and singletons are one,
/// navigation and widget state are per view. A root that holds a global
/// key (a navigator key the app keeps) can't be in two views at once: the
/// entry then shows the views beside the first as refused and says so on
/// [channel] ([RefusedViews]). An app that installs a binding of its own
/// finds this one there first, and one that runs in a zone of its own
/// (`runZonedGuarded`) is told the binding was made outside it.
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

  /// The channel the entry says on, to the first client, which views it
  /// refused.
  static const channel = RaccoonEntrypoint.viewsChannel;

  /// The package the pubspec in [projectDirectory] names, or null.
  static String? packageOf(String projectDirectory) =>
      RaccoonEntrypoint.packageOf(projectDirectory);

  /// The entry point's source, importing the app's main from [mainImport].
  static String sourceFor(String mainImport) =>
      RaccoonEntrypoint.sourceFor(mainImport, views: true);
}

/// Views a views run's app could not be laid out in, as the entry says on
/// [ViewsEntrypoint.channel]: they show a notice in place of the app, and
/// their clients may as well go.
final class RefusedViews {
  const RefusedViews({required this.views, required this.reason, this.error});

  /// The views' ids.
  final List<int> views;

  /// Why: `globalKey`, a global key the app holds being in its first view.
  final String reason;

  /// The framework's error, its first line.
  final String? error;

  /// The entry's message, or null for one that isn't such.
  static RefusedViews? parse(Uint8List data) {
    final Object? message;
    try {
      message = jsonDecode(utf8.decode(data));
    } on FormatException {
      return null;
    }
    return switch (message) {
      {'refused': final List ids, 'reason': final String reason} &&
          final Map map =>
        RefusedViews(
          views: [...ids.whereType<int>()],
          reason: reason,
          error: switch (map['error']) {
            final String error => error,
            _ => null,
          },
        ),
      _ => null,
    };
  }
}

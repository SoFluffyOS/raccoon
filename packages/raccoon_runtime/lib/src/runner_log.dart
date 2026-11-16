import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/src/app_sizes.dart';

/// Where a log line came from.
enum DeviceLogSource {
  /// The app: its prints, the engine's lines, its errors.
  app,

  /// The runner itself: its `🦝` lines, with their timings.
  runner,

  /// The Flutter tool: progress, hot reload, build and compile errors.
  tool;

  /// The source a line of an app's or a runner's output is from: the
  /// runner's own lines start with `🦝`, after the timestamp `runner.log`
  /// puts first.
  static DeviceLogSource of(String line) => switch (RunnerLog.untimed(
    line,
  ).trimLeft().startsWith('🦝')) {
    true => DeviceLogSource.runner,
    false => DeviceLogSource.app,
  };
}

/// One line of a log, and where it came from.
final class DeviceLogLine {
  const DeviceLogLine(this.source, this.text);

  /// A line of an app's or a runner's output, its source told by its text.
  factory DeviceLogLine.output(String text) =>
      DeviceLogLine(DeviceLogSource.of(text), text);

  final DeviceLogSource source;
  final String text;

  Map<String, Object?> toJson() => {'source': source.name, 'text': text};

  @override
  String toString() => '[${source.name}] $text';
}

/// What a runner the device helper started wrote, timestamped:
/// `<data>/raccoon/data/<app>/runner.log`, beside the app's saved size
/// ([AppSizes]). The helper starts it afresh with each run, from any tool:
/// an editor's run, a terminal's, a host's.
final class RunnerLog {
  const RunnerLog(this.directory);

  /// The helper's data directory, as [AppSizes.forHost] finds it.
  factory RunnerLog.forHost(Map<String, String> environment) =>
      RunnerLog(AppSizes.forHost(environment).directory);

  /// The directory each app's folder sits under.
  final String directory;

  /// The log of [app] (`hello@phone`).
  File fileOf(String app) => File(p.join(directory, app, 'runner.log'));

  /// [app]'s lines, oldest first; none when it has no log.
  List<DeviceLogLine> read(String app) {
    final file = fileOf(app);
    try {
      return [
        for (final line in file.readAsLinesSync())
          if (line.isNotEmpty) DeviceLogLine.output(line),
      ];
    } on FileSystemException {
      return const [];
    }
  }

  static final _timestamp = RegExp(r'^\d\d:\d\d:\d\d\.\d{3} ');

  /// [line] without the `12:34:56.789 ` the helper puts first.
  static String untimed(String line) => line.replaceFirst(_timestamp, '');
}

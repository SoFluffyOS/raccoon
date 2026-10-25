import 'package:raccoon/raccoon.dart';

/// Why a hosted app stopped before its first frame, as its log tells it:
/// the exception `main()` died of, the channels nothing answered, and the
/// plugins those channels belong to when the runner's plugin report says
/// they cannot work on this host.
///
/// An app that awaits a plugin with no implementation here before `runApp`,
/// `await Firebase.initializeApp()` on Linux say, gets a null reply, throws,
/// and never draws. Without this the pane would sit there blank.
final class StartupFailure {
  const StartupFailure({
    this.exception,
    this.stackTrace = const [],
    this.channels = const [],
    this.plugins = const [],
  });

  /// What the engine prints ahead of an exception nothing caught, on the
  /// same line: `Unhandled Exception: PlatformException(...)`. The Dart VM
  /// on its own prints `Unhandled exception:` and the exception on the next
  /// line; both are read.
  static final _unhandled = RegExp(
    r'Unhandled exception:\s*(.*)$',
    caseSensitive: false,
  );

  /// What the runner prints when it answers a channel with nothing, once
  /// per channel (see `EngineHost::RespondNoPlugin`).
  static final _unanswered = RegExp(
    r'(?:🦝|raccoon_runner:) nothing answered (\S+) \(',
  );

  /// The exception's text, such as `PlatformException(channel-error, ...)`;
  /// null when the log has no exception, only channels nothing answered.
  final String? exception;

  /// The stack lines printed under [exception].
  final List<String> stackTrace;

  /// The channels the runner answered with nothing, each once, in order.
  final List<String> channels;

  /// The plugins of the report that [channels] belong to and that cannot
  /// work on this host, see [pluginOf].
  final List<PluginReport> plugins;

  /// One line per plugin of [plugins], such as `firebase_core has no Linux
  /// implementation`.
  List<String> get hints => [for (final plugin in plugins) hintFor(plugin)];

  /// Reads an app's log [lines] from before its first frame. Null when they
  /// tell of no failure: no exception nothing caught, no channel nothing
  /// answered.
  static StartupFailure? fromLog(Iterable<String> lines, {Plugins? plugins}) {
    final all = lines.toList();
    String? exception;
    var stack = <String>[];
    final channels = <String>[];
    for (var i = 0; i < all.length; i++) {
      final line = all[i];
      if (_unanswered.firstMatch(line) case final match?) {
        final channel = match.group(1) ?? '';
        if (!channels.contains(channel)) channels.add(channel);
        continue;
      }
      final match = _unhandled.firstMatch(line);
      if (match == null) continue;
      // The latest one wins: it is the one main() died of.
      var text = (match.group(1) ?? '').trim();
      var next = i + 1;
      if (text.isEmpty && next < all.length) text = all[next++].trim();
      stack = [
        for (var k = next; k < all.length && _isStackLine(all[k]); k++)
          all[k].trim(),
      ];
      exception = text;
    }
    if (exception == null && channels.isEmpty) return null;
    final reports = plugins?.plugins ?? const <PluginReport>[];
    final failing = <PluginReport>[];
    for (final channel in channels) {
      final plugin = pluginOf(channel, reports);
      if (plugin == null || failing.contains(plugin)) continue;
      failing.add(plugin);
    }
    return StartupFailure(
      exception: exception,
      stackTrace: stack,
      channels: channels,
      plugins: failing,
    );
  }

  /// The plugin of [reports] that [channel] belongs to, among the ones that
  /// cannot work on this host (no implementation, did not load, made no
  /// library); null when none matches.
  ///
  /// A heuristic: nothing ties a channel to its package, but plugins name
  /// their channels after themselves. A method channel is usually
  /// `plugins.flutter.io/firebase_core` or `<domain>/<plugin>`, a Pigeon one
  /// `dev.flutter.pigeon.firebase_core_platform_interface.FirebaseCoreHostApi
  /// .initializeCore`, after the federated package that declares it. So a
  /// plugin matches when a segment of the channel, split at `.`, `/` and
  /// `:`, is its name, or its name and one of the federated packages'
  /// suffixes ([federatedSuffixes]). The longest name that matches wins.
  static PluginReport? pluginOf(
    String channel,
    Iterable<PluginReport> reports,
  ) {
    final segments = channel.split(RegExp('[./:]'));
    PluginReport? best;
    for (final report in reports) {
      if (!_cannotWork(report)) continue;
      final name = report.name;
      if (name.isEmpty) continue;
      final matches = segments.any(
        (segment) =>
            segment == name ||
            federatedSuffixes.any((suffix) => segment == '$name$suffix'),
      );
      if (!matches) continue;
      if (best == null || name.length > best.name.length) best = report;
    }
    return best;
  }

  /// What a federated plugin's packages add to its name: the interface and
  /// one package per platform.
  static const federatedSuffixes = [
    '_platform_interface',
    '_android',
    '_ios',
    '_foundation',
    '_darwin',
    '_macos',
    '_linux',
    '_windows',
    '_web',
  ];

  /// A line for [plugin]: `firebase_core has no Linux implementation`, with
  /// the report's own words for the host where it has them.
  static String hintFor(PluginReport plugin) => switch (plugin.state) {
    PluginState.PLUGIN_STATE_NO_HOST => switch (plugin.detail) {
      '' => '${plugin.name} has no implementation for this host',
      final detail => '${plugin.name} has $detail',
    },
    PluginState.PLUGIN_STATE_FAILED => switch (plugin.detail) {
      '' => '${plugin.name} did not load',
      final detail => '${plugin.name} did not load: $detail',
    },
    PluginState.PLUGIN_STATE_BUILT_NOTHING =>
      '${plugin.name} built and made no library',
    _ => plugin.name,
  };

  static bool _cannotWork(PluginReport report) => switch (report.state) {
    PluginState.PLUGIN_STATE_NO_HOST ||
    PluginState.PLUGIN_STATE_FAILED ||
    PluginState.PLUGIN_STATE_BUILT_NOTHING => true,
    _ => false,
  };

  /// Whether [line] can change what [fromLog] finds in a log that already
  /// holds a failure, or start one: a channel nobody answered, an
  /// unhandled exception, or a line of its stack. Most lines can't, so a
  /// reader need not read the whole log again for them.
  static bool tells(String line) =>
      _unanswered.hasMatch(line) ||
      _unhandled.hasMatch(line) ||
      _isStackLine(line);

  /// Whether [line] marks an unhandled exception and leaves its text to the
  /// next line, as the Dart VM's own form does: that line tells too.
  static bool leavesTextToNext(String line) =>
      (_unhandled.firstMatch(line)?.group(1) ?? 'x').trim().isEmpty;

  static bool _isStackLine(String line) {
    final text = line.trim();
    return text.startsWith('#') || text == '<asynchronous suspension>';
  }

  @override
  bool operator ==(Object other) =>
      other is StartupFailure &&
      other.exception == exception &&
      _same(other.stackTrace, stackTrace) &&
      _same(other.channels, channels) &&
      _same(other.hints, hints);

  @override
  int get hashCode => Object.hash(
    exception,
    Object.hashAll(stackTrace),
    Object.hashAll(channels),
    Object.hashAll(hints),
  );

  static bool _same(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() => [
    if (exception case final exception?) exception,
    ...hints,
    if (exception == null)
      for (final channel in channels) 'nothing answered $channel',
  ].join('; ');
}

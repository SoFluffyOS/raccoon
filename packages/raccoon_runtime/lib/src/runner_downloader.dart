import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/src/runner_version.dart';

/// A download that did not work, with what to tell the user.
final class DownloadFailed implements Exception {
  const DownloadFailed(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A release of the runner with an archive for this host.
final class RunnerRelease {
  const RunnerRelease({
    required this.version,
    required this.asset,
    required this.prerelease,
    this.sha256,
  });

  final RunnerVersion version;

  /// The archive's download URL.
  final Uri asset;

  final bool prerelease;

  /// The archive's SHA-256, in hex, as the release lists it; null for a
  /// release that lists none.
  final String? sha256;
}

/// Where a downloaded release of the runner unpacks: the binary beside
/// `VERSION`, with `tool/raccoon-device` and `tool/engine_dir.sh`, the way
/// the runner's `tool/package.sh` packs it.
final class PrebuiltRunner {
  const PrebuiltRunner(this.directory, {this.isWindows = false});

  final String directory;

  final bool isWindows;

  String get binary => p.join(directory, switch (isWindows) {
    true => 'raccoon_runner.exe',
    false => 'raccoon_runner',
  });

  /// The script the Flutter tool's custom device entry points at.
  String get deviceHelper => p.join(directory, 'tool', 'raccoon-device');

  /// The version that was downloaded.
  String get versionFile => p.join(directory, 'VERSION');

  /// Whether a runner is there, and which: its binary and its device
  /// helper both, so a runner half unpacked is none.
  RunnerVersion? get version => switch (File(binary).existsSync() &&
      File(deviceHelper).existsSync()) {
    true => RunnerVersion.read(versionFile),
    false => null,
  };
}

/// Fetches the prebuilt runner from the Raccoon repository's GitHub
/// releases, the ones tagged `runner-v*` (plain `v*` tags are the protocol
/// package's): the newest release compatible with a pinned version, and no
/// older, that carries an archive for this host, unpacked into a
/// [PrebuiltRunner]'s directory. The archives come from the runner's `tool/package.sh`:
/// `raccoon_runner-<version>-<platform>.tar.gz`, flat, the binary at the
/// root. Nothing here sets a quarantine attribute, so the binary runs on
/// macOS as it is.
final class RunnerDownloader {
  RunnerDownloader({
    Uri? releases,
    String? platform,
    this.stallTimeout = const Duration(seconds: 30),
    this.userAgent = 'raccoon_runtime',
  }) : releases = releases ?? defaultReleases,
       platform = platform ?? hostPlatform;

  /// How long a connection or a download may go without a byte before it
  /// counts as failed, rather than leave setup waiting for good.
  final Duration stallTimeout;

  /// What the requests call themselves: GitHub's API wants a name.
  final String userAgent;

  /// The Raccoon repository's releases, newest first, prereleases included.
  static final defaultReleases = Uri.parse(
    'https://api.github.com/repos/SoFluffyOS/raccoon/releases?per_page=100',
  );

  /// What a runner release's tag starts with.
  static const tagPrefix = 'runner-v';

  /// The archives' platform name for the host this process runs on.
  static final String hostPlatform = platformFor(
    Platform.operatingSystem,
    Abi.current(),
  );

  /// The archives' platform name for [operatingSystem] on [abi]:
  /// `linux-x64`, `linux-arm64`, `macos-arm64`, `macos-x64`, `windows-x64`
  /// or `windows-arm64`.
  static String platformFor(String operatingSystem, Abi abi) {
    final architecture = switch (abi) {
      Abi.linuxArm64 || Abi.macosArm64 || Abi.windowsArm64 => 'arm64',
      Abi.linuxX64 || Abi.macosX64 || Abi.windowsX64 => 'x64',
      _ => throw UnsupportedError('no prebuilt runner for $abi'),
    };
    return switch (operatingSystem) {
      'linux' || 'macos' || 'windows' => '$operatingSystem-$architecture',
      _ => throw UnsupportedError('no prebuilt runner for $operatingSystem'),
    };
  }

  /// The archive's name in a release, as `tool/package.sh` names it.
  static String assetName(RunnerVersion version, String platform) =>
      'raccoon_runner-$version-$platform.tar.gz';

  final Uri releases;

  /// The archives' platform name this downloader serves, see [platformFor].
  final String platform;

  /// The highest release compatible with [version], and no older than it,
  /// that has an archive for [platform], or null when there is none. A
  /// release [version] takes releases only; a prerelease takes either.
  /// Throws [DownloadFailed] when the list cannot be fetched or read.
  Future<RunnerRelease?> find(RunnerVersion version) async {
    final body = await _get(releases, accept: 'application/vnd.github+json');
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(body));
    } on FormatException {
      throw DownloadFailed('$releases did not answer with JSON');
    }
    if (decoded is! List) {
      throw DownloadFailed('$releases did not answer with a list of releases');
    }
    // GitHub lists releases by when they were made, so a patch published
    // after a newer one comes first.
    RunnerRelease? best;
    for (final entry in decoded) {
      if (entry is! Map || entry['draft'] == true) continue;
      final tag = entry['tag_name'];
      if (tag is! String || !tag.startsWith(tagPrefix)) continue;
      final candidate = RunnerVersion.parse(tag);
      if (candidate == null || !candidate.isCompatibleWith(version)) continue;
      if (candidate.isOlderThan(version)) continue;
      if (version.prerelease.isEmpty && candidate.prerelease.isNotEmpty) {
        continue;
      }
      if (best != null && !best.version.isOlderThan(candidate)) continue;
      final found = _asset(entry['assets'], assetName(candidate, platform));
      if (found == null) continue;
      best = RunnerRelease(
        version: candidate,
        asset: Uri.parse(found.url),
        prerelease: entry['prerelease'] == true,
        sha256: found.sha256,
      );
    }
    return best;
  }

  /// Downloads [release]'s archive and unpacks it into [into], replacing
  /// what was there. The binary and the tools come out executable.
  Future<void> install(RunnerRelease release, PrebuiltRunner into) async {
    final bytes = await _get(release.asset);
    // A download cut short, or changed on the way, is not unpacked.
    if (release.sha256 case final expected?) {
      final got = await Isolate.run(() => sha256.convert(bytes).toString());
      if (got != expected.toLowerCase()) {
        throw DownloadFailed(
          '${release.asset} did not arrive whole (its SHA-256 is $got, '
          'the release says $expected)',
        );
      }
    }
    final directory = Directory(into.directory);
    // A folder of its own: two hosts setting up at once (two editor
    // windows, an editor and the simulator) each unpack apart.
    final staging =
        '${directory.path}.partial-$pid-${DateTime.now().microsecondsSinceEpoch}';
    // Decoding and writing a runner's archive takes long enough to freeze
    // the window, so it runs on its own isolate.
    final binary = p.basename(into.binary);
    try {
      await Isolate.run(() => _unpack(bytes, release.asset, staging, binary));
    } on FileSystemException catch (error) {
      _deleteIfAny(Directory(staging));
      throw DownloadFailed(
        'cannot unpack the runner into $staging: '
        '${error.osError?.message ?? error.message}',
      );
    }
    // The old runner moves aside whole before the new one moves in, and
    // comes back if that fails: a file held open (a running runner, on
    // Windows) stops the move, not a delete halfway through.
    _deleteLeftovers(directory);
    final aside = Directory(
      '${directory.path}.old-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    if (directory.existsSync()) {
      try {
        directory.renameSync(aside.path);
      } on FileSystemException catch (error) {
        _deleteIfAny(Directory(staging));
        throw DownloadFailed(
          'cannot replace the runner in ${directory.path}, is it running? '
          '${error.osError?.message ?? error.message}',
        );
      }
    }
    try {
      await _moveIn(Directory(staging), directory.path);
    } on FileSystemException catch (error) {
      _deleteIfAny(Directory(staging));
      if (aside.existsSync() && !directory.existsSync()) {
        aside.renameSync(directory.path);
      }
      throw DownloadFailed(
        'cannot move the runner into ${directory.path}: '
        '${error.osError?.message ?? error.message}',
      );
    }
    _deleteIfAny(aside);
  }

  /// Moves [staging] in as [target]. Windows refuses for a while as
  /// antivirus scans the runner just written (a whole executable, seconds
  /// on a busy machine): tried again there for up to ten seconds, rather
  /// than download it again.
  static Future<void> _moveIn(Directory staging, String target) async {
    for (var attempt = 0; ; attempt++) {
      try {
        staging.renameSync(target);
        return;
      } on FileSystemException {
        if (!Platform.isWindows ||
            attempt >= 100 ||
            Directory(target).existsSync()) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  /// Deletes what earlier installs left next to [directory]: runners moved
  /// aside and not deleted then, and unpacked folders of installs killed
  /// midway. Only those an hour old, by the time in their names: another
  /// install may be using a newer one right now.
  static void _deleteLeftovers(Directory directory) {
    final parent = directory.parent;
    if (!parent.existsSync()) return;
    final base = p.basename(directory.path);
    final made = RegExp(
      '^${RegExp.escape(base)}\\.(?:old|partial)-\\d+-(\\d+)\$',
    );
    final before = DateTime.now().subtract(const Duration(hours: 1));
    for (final entry in parent.listSync(followLinks: false)) {
      if (entry is! Directory) continue;
      final micros = int.tryParse(
        made.firstMatch(p.basename(entry.path))?.group(1) ?? '',
      );
      if (micros == null) continue;
      if (DateTime.fromMicrosecondsSinceEpoch(micros).isBefore(before)) {
        _deleteIfAny(entry);
      }
    }
  }

  /// Deletes [directory] if it is there; one a held file keeps is left for
  /// the next install.
  static void _deleteIfAny(Directory directory) {
    try {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    } on FileSystemException {
      return;
    }
  }

  /// Unpacks the tar.gz [bytes] into [staging], afresh; the files keep
  /// their executable bit, [binary] always has one.
  static void _unpack(
    List<int> bytes,
    Uri source,
    String staging,
    String binary,
  ) {
    final Archive archive;
    try {
      final data = const GZipDecoder().decodeBytes(bytes);
      // A cut archive decodes into fewer files without a word: what came
      // out has to be what the gzip's trailer says went in.
      if (!_wholeGzip(bytes, data)) {
        throw DownloadFailed('$source arrived cut short');
      }
      archive = TarDecoder().decodeBytes(data);
    } on DownloadFailed {
      rethrow;
    } on Object catch (error) {
      throw DownloadFailed('$source is not a tar.gz archive: $error');
    }
    final folder = Directory(staging);
    if (folder.existsSync()) folder.deleteSync(recursive: true);
    folder.createSync(recursive: true);
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final target = p.normalize(p.join(staging, entry.name));
      // An entry that would land outside the folder is left out.
      if (!p.isWithin(staging, target)) continue;
      final file =
          File(target)
            ..parent.createSync(recursive: true)
            ..writeAsBytesSync(entry.content);
      if (entry.mode & _ownerExecutable != 0) _makeExecutable(file);
    }
    final made = File(p.join(staging, binary));
    if (!made.existsSync()) {
      folder.deleteSync(recursive: true);
      throw DownloadFailed('No $binary in $source');
    }
    _makeExecutable(made);
  }

  static const _ownerExecutable = 0x40;

  /// Whether [data] is all [gzip] holds: a gzip ends with its data's CRC-32
  /// and length (little-endian), which a cut one has not.
  static bool _wholeGzip(List<int> gzip, List<int> data) {
    if (gzip.length < 18) return false;
    int word(int at) =>
        gzip[at] | gzip[at + 1] << 8 | gzip[at + 2] << 16 | gzip[at + 3] << 24;
    final end = gzip.length;
    return word(end - 4) == data.length & 0xffffffff &&
        word(end - 8) == getCrc32(data);
  }

  /// The asset [name]'s download URL, and its SHA-256 when the release
  /// lists one (GitHub's `digest`, `sha256:<hex>`).
  static ({String url, String? sha256})? _asset(Object? assets, String name) {
    if (assets is! List) return null;
    for (final asset in assets) {
      if (asset case {
        'name': final String assetName,
        'browser_download_url': final String url,
      } when assetName == name) {
        final digest = switch (asset['digest']) {
          final String value when value.startsWith('sha256:') => value
              .substring('sha256:'.length),
          _ => null,
        };
        return (url: url, sha256: digest);
      }
    }
    return null;
  }

  static void _makeExecutable(File file) {
    if (Platform.isWindows) return;
    Process.runSync('chmod', ['755', file.path]);
  }

  Future<List<int>> _get(Uri uri, {String? accept}) async {
    final client =
        HttpClient()
          ..userAgent = userAgent
          ..connectionTimeout = stallTimeout;
    try {
      final request = await client.getUrl(uri);
      if (accept case final accept?) {
        request.headers.set(HttpHeaders.acceptHeader, accept);
      }
      final response = await request.close().timeout(stallTimeout);
      if (response.statusCode != HttpStatus.ok) {
        throw DownloadFailed('${response.statusCode} for $uri');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(stallTimeout)) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } on IOException catch (error) {
      throw DownloadFailed('$uri: $error');
    } on TimeoutException {
      throw DownloadFailed(
        '$uri: nothing came for ${stallTimeout.inSeconds} seconds',
      );
    } finally {
      // Forced: a stalled connection would otherwise stay open.
      client.close(force: true);
    }
  }
}

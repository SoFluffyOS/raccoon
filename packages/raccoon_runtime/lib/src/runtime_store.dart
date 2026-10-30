import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// Fetches bytes from [uri]; tests inject one that serves a zip from memory.
typedef Downloader = Future<List<int>> Function(Uri uri);

/// The engine artifacts for one engine revision on one host platform.
final class EngineRuntime {
  const EngineRuntime({
    required this.revision,
    required this.directory,
    required this.platform,
  });

  /// The engine revision, as an SDK's engine stamp names it.
  final String revision;

  /// Where the engine's files are unpacked.
  final String directory;

  /// The bucket's name for the host, see [RuntimeStore.platformFor].
  final String platform;

  /// The embedder library the runner loads.
  String get engineLibrary =>
      p.join(directory, RuntimeStore.engineLibraryOf(platform));

  /// The embedder API's header: `flutter_embedder.h`, or the framework's
  /// `FlutterEmbedder.h` on macOS.
  String get embedderHeader =>
      p.join(directory, RuntimeStore.embedderHeaderOf(platform));
}

/// Keeps one engine per revision for one host under a cache directory,
/// downloading the prebuilt debug embedder from the Flutter infra bucket when
/// missing.
final class RuntimeStore {
  RuntimeStore({
    required this.cacheDirectory,
    Downloader? download,
    String? platform,
  }) : platform = platform ?? hostPlatform,
       _download = download ?? httpDownload;

  /// `$XDG_CACHE_HOME/raccoon/engines`, or `~/.cache/raccoon/engines`, as
  /// the runner's `tool/engine_dir.sh` keeps them unless
  /// `RACCOON_ENGINE_CACHE` says otherwise. Windows programs rarely
  /// see a `HOME`; the user's profile is the home Git Bash gives that tool.
  factory RuntimeStore.forHost(Map<String, String> environment) {
    if (environment['RACCOON_ENGINE_CACHE'] case final cache?
        when cache.isNotEmpty) {
      return RuntimeStore(cacheDirectory: cache);
    }
    final cacheHome = switch (environment['XDG_CACHE_HOME']) {
      final dir? when dir.isNotEmpty => dir,
      _ => p.join(homeOf(environment), '.cache'),
    };
    return RuntimeStore(
      cacheDirectory: p.join(cacheHome, 'raccoon', 'engines'),
    );
  }

  /// The bucket's name for the host this process runs on.
  static final String hostPlatform = platformFor(
    Platform.operatingSystem,
    Abi.current(),
  );

  /// The bucket's name for [operatingSystem] on [abi]: `linux-x64`,
  /// `linux-arm64`, `windows-x64`, `windows-arm64`, or `darwin` for the one
  /// universal macOS framework.
  static String platformFor(String operatingSystem, Abi abi) {
    final architecture = switch (abi) {
      Abi.linuxArm64 || Abi.macosArm64 || Abi.windowsArm64 => 'arm64',
      Abi.linuxX64 || Abi.macosX64 || Abi.windowsX64 => 'x64',
      _ => throw UnsupportedError('no prebuilt embedder for $abi'),
    };
    return switch (operatingSystem) {
      'linux' => 'linux-$architecture',
      'windows' => 'windows-$architecture',
      'macos' => 'darwin',
      _ => throw UnsupportedError('no prebuilt embedder for $operatingSystem'),
    };
  }

  /// The embedder library's path inside a runtime directory.
  static String engineLibraryOf(String platform) => switch (platform) {
    'linux-x64' || 'linux-arm64' => 'libflutter_engine.so',
    'windows-x64' || 'windows-arm64' => 'flutter_engine.dll',
    'darwin' => p.join('FlutterEmbedder.framework', 'FlutterEmbedder'),
    _ => throw ArgumentError.value(platform, 'platform'),
  };

  /// The embedder header's path inside a runtime directory.
  static String embedderHeaderOf(String platform) => switch (platform) {
    'darwin' => p.join(
      'FlutterEmbedder.framework',
      'Headers',
      'FlutterEmbedder.h',
    ),
    _ => 'flutter_embedder.h',
  };

  /// The framework zip unpacks to the framework's contents, so it goes into a
  /// folder of its own; the other zips carry the files at their root.
  static String _extractionRoot(String platform) => switch (platform) {
    'darwin' => 'FlutterEmbedder.framework',
    _ => '',
  };

  /// The root the engines sit under, a folder per revision and platform.
  final String cacheDirectory;

  /// The bucket's name for the host this store serves, see [platformFor].
  final String platform;

  final Downloader _download;

  /// The bucket path of the embedder zip for [revision] and [platform],
  /// under [base]: where Flutter itself downloads from, its
  /// `FLUTTER_STORAGE_BASE_URL` when set (a mirror where Google's storage
  /// is out of reach), else Google's.
  static Uri artifactUri(String revision, {String? platform, String? base}) {
    final name = platform ?? hostPlatform;
    final file = switch (name) {
      'darwin' => 'darwin-x64/FlutterEmbedder.framework.zip',
      _ => '$name/$name-embedder.zip',
    };
    final storage =
        base ??
        Platform.environment['FLUTTER_STORAGE_BASE_URL'] ??
        'https://storage.googleapis.com';
    final root =
        storage.endsWith('/')
            ? storage.substring(0, storage.length - 1)
            : storage;
    return Uri.parse('$root/flutter_infra_release/flutter/$revision/$file');
  }

  /// The engine revision an SDK at [sdkRoot] was built with, from its stamp.
  static String? revisionOfSdk(String sdkRoot) {
    for (final candidate in [
      p.join(sdkRoot, 'bin', 'cache', 'engine.stamp'),
      p.join(sdkRoot, 'bin', 'internal', 'engine.version'),
    ]) {
      final file = File(candidate);
      if (!file.existsSync()) continue;
      final String revision;
      try {
        revision = file.readAsStringSync().trim();
      } on FileSystemException {
        continue;
      }
      if (revision.isNotEmpty) return revision;
    }
    return null;
  }

  /// The SDK root for a `flutter` executable, following symlinks.
  static String sdkRootOfFlutter(String flutterExecutable) {
    final resolved = File(flutterExecutable).resolveSymbolicLinksSync();
    return p.dirname(p.dirname(resolved));
  }

  /// The user's home: `HOME`, or on Windows, where it is seldom set,
  /// `USERPROFILE`.
  static String homeOf(Map<String, String> environment) =>
      switch (environment['HOME']) {
        final home? when home.isNotEmpty => home,
        _ => environment['USERPROFILE'] ?? '',
      };

  /// The SDK root behind the `flutter` on the PATH, or null without one.
  /// Windows' `where` lists the shell script and `flutter.bat`, both in
  /// the SDK's `bin`.
  static String? sdkRootOnPath() {
    final which =
        Process.runSync(Platform.isWindows ? 'where' : 'which', [
          'flutter',
        ]).stdout.toString().trim();
    if (which.isEmpty) return null;
    return sdkRootOfFlutter(const LineSplitter().convert(which).first.trim());
  }

  /// The ICU data file an SDK ships for [platform]. The SDK keeps one macOS
  /// engine directory, `darwin-x64`, for both Mac architectures.
  static String icuDataOfSdk(String sdkRoot, {String? platform}) {
    final directory = switch (platform ?? hostPlatform) {
      'darwin' => 'darwin-x64',
      final name => name,
    };
    return p.join(
      sdkRoot,
      'bin',
      'cache',
      'artifacts',
      'engine',
      directory,
      'icudtl.dat',
    );
  }

  /// Where [revision]'s engine for [platform] goes, installed or not.
  String directoryFor(String revision) =>
      p.join(cacheDirectory, revision, platform);

  /// The installed runtime for [revision], or null.
  EngineRuntime? installed(String revision) {
    final runtime = EngineRuntime(
      revision: revision,
      directory: directoryFor(revision),
      platform: platform,
    );
    if (!File(runtime.engineLibrary).existsSync()) return null;
    return runtime;
  }

  /// Returns the runtime for [revision], downloading and extracting it first
  /// when it is not installed. The unzip runs on another isolate, calls that
  /// overlap share one install, and an install another store finished
  /// meanwhile is kept.
  Future<EngineRuntime> ensure(String revision) {
    if (installed(revision) case final runtime?) return Future.value(runtime);
    // Calls that overlap share one install: each would stage its own, but
    // one download is enough (#113).
    return _installing[revision] ??= _install(revision).whenComplete(() {
      // A block, not an arrow: remove returns this very future, and
      // whenComplete would wait for it.
      _installing.remove(revision);
    });
  }

  final _installing = <String, Future<EngineRuntime>>{};

  Future<EngineRuntime> _install(String revision) async {
    final uri = artifactUri(revision, platform: platform);
    final bytes = await _download(uri);
    final directory = Directory(directoryFor(revision));
    directory.parent.createSync(recursive: true);
    _removeStaleStaging(directory);
    // A staging folder of its own: another store installing the same
    // revision meanwhile never writes into it.
    final staging = directory.parent.createTempSync(
      '${p.basename(directory.path)}.partial',
    );
    try {
      // On another isolate: unzipping and writing an engine takes a few
      // hundred milliseconds, and the caller is often a host's UI (#113).
      final root = p.join(staging.path, _extractionRoot(platform));
      await _unpack(bytes, root);
      final library = File(p.join(staging.path, engineLibraryOf(platform)));
      if (!library.existsSync()) {
        throw StateError('no ${engineLibraryOf(platform)} in $uri');
      }
      _makeExecutable(library);
      // Another store may have installed it meanwhile, and a runner may
      // already use it: a good install stays. Only one in the way that is
      // not good (a crash's) is deleted, once moving in fails: deleting
      // first could take another store's install, done in between (#230).
      if (installed(revision) case final runtime?) return runtime;
      try {
        await _moveIn(staging, directory.path);
      } on FileSystemException {
        if (installed(revision) case final runtime?) return runtime;
        if (!directory.existsSync()) rethrow;
        directory.deleteSync(recursive: true);
        await _moveIn(staging, directory.path);
      }
    } finally {
      _deleteQuietly(staging);
    }
    return EngineRuntime(
      revision: revision,
      directory: directory.path,
      platform: platform,
    );
  }

  /// Staging folders an install left when its process was killed: an hour
  /// old and more, so no install is still writing them.
  static void _removeStaleStaging(Directory directory) {
    final prefix = '${p.basename(directory.path)}.partial';
    final before = DateTime.now().subtract(const Duration(hours: 1));
    for (final entry in directory.parent.listSync()) {
      if (entry is! Directory || !p.basename(entry.path).startsWith(prefix)) {
        continue;
      }
      if (entry.statSync().modified.isBefore(before)) _deleteQuietly(entry);
    }
  }

  /// A cleanup that fails leaves the folder; it never hides the error the
  /// install itself may be throwing.
  /// Moves [staging] in as [target]. Windows refuses for a moment while
  /// antivirus or the indexer holds a file just written: tried again there
  /// for a few seconds, rather than download the engine again (#230).
  static Future<void> _moveIn(Directory staging, String target) async {
    for (var attempt = 0; ; attempt++) {
      try {
        staging.renameSync(target);
        return;
      } on FileSystemException {
        if (!Platform.isWindows ||
            attempt >= 30 ||
            Directory(target).existsSync()) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  static void _deleteQuietly(Directory directory) {
    try {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    } on FileSystemException {
      // Left for the next install to clear.
    }
  }

  /// Unzips [bytes] under [root] on another isolate. Static, so the closure
  /// takes only what it is given to the other isolate, not the store.
  static Future<void> _unpack(List<int> bytes, String root) =>
      Isolate.run(() => _extract(ZipDecoder().decodeBytes(bytes), root));

  /// Writes [archive]'s files and symbolic links under [root]; the framework
  /// is mostly links into its `Versions/A`.
  static void _extract(Archive archive, String root) {
    for (final entry in archive.files) {
      if (!_inside(entry.name)) continue;
      final target = p.join(root, entry.name);
      if (entry.symbolicLink case final link? when link.isNotEmpty) {
        if (!_inside(link)) continue;
        Directory(p.dirname(target)).createSync(recursive: true);
        Link(target).createSync(link);
        continue;
      }
      if (!entry.isFile) continue;
      File(target)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(entry.content);
    }
  }

  /// Whether an archive's [path] stays where it is put: relative, and never
  /// stepping up. A link that steps up at all could chain out of the
  /// folder (`x` to `..`, then `x/y` to `..`), and a file written through
  /// it with it (#299). No colon either: on Windows `C:x` is on drive C.
  static bool _inside(String path) =>
      !p.posix.isAbsolute(path) &&
      !p.windows.isAbsolute(path) &&
      !path.contains(':') &&
      !path.split(_separators).contains('..');

  static final _separators = RegExp(r'[/\\]');

  static void _makeExecutable(File file) {
    if (Platform.isWindows) return;
    Process.runSync('chmod', ['755', file.path]);
  }

  /// Downloads [uri] whole. A connection, or a stretch of the body, with
  /// no byte for [stallTimeout] fails with a [TimeoutException]: a stall
  /// would otherwise hold every [ensure] of that revision for good (#134).
  static Future<List<int>> httpDownload(
    Uri uri, {
    Duration stallTimeout = const Duration(seconds: 30),
  }) async {
    final client = HttpClient()..connectionTimeout = stallTimeout;
    try {
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(stallTimeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('${response.statusCode} for $uri', uri: uri);
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(stallTimeout)) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } finally {
      // Forced: a stalled connection would otherwise stay open.
      client.close(force: true);
    }
  }
}

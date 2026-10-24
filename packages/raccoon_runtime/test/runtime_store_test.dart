import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

List<int> _linuxEmbedderZip() {
  final archive =
      Archive()
        ..addFile(
          ArchiveFile.bytes('libflutter_engine.so', [0x7f, 0x45, 0x4c, 0x46]),
        )
        ..addFile(
          ArchiveFile.string(
            'flutter_embedder.h',
            '#define FLUTTER_ENGINE_VERSION 1\n',
          ),
        );
  return ZipEncoder().encodeBytes(archive);
}

/// The framework zip's shape: the contents of FlutterEmbedder.framework at
/// the root, with the usual links into Versions/A.
List<int> _darwinEmbedderZip() {
  final archive =
      Archive()
        ..addFile(ArchiveFile.bytes('Versions/A/FlutterEmbedder', [0xcf, 0xfa]))
        ..addFile(
          ArchiveFile.string(
            'Versions/A/Headers/FlutterEmbedder.h',
            '#define FLUTTER_ENGINE_VERSION 1\n',
          ),
        )
        ..addFile(_symlink('Versions/Current', 'A'))
        ..addFile(
          _symlink('FlutterEmbedder', 'Versions/Current/FlutterEmbedder'),
        )
        ..addFile(_symlink('Headers', 'Versions/Current/Headers'));
  return _madeOnUnix(ZipEncoder().encodeBytes(archive));
}

/// A zip stores a symbolic link as an entry in link mode whose bytes are the
/// target.
ArchiveFile _symlink(String name, String target) =>
    ArchiveFile.string(name, target)..mode = 0xA1FF;

/// The archive package writes every zip as made on MS-DOS and reads link
/// modes only from zips made on Unix, which the bucket's are: stamp each
/// central directory entry's "version made by" with Unix.
Uint8List _madeOnUnix(List<int> zip) {
  final bytes = Uint8List.fromList(zip);
  final data = ByteData.sublistView(bytes);
  const endSignature = 0x06054b50;
  const entrySignature = 0x02014b50;
  const unix = 3;
  var end = bytes.length - 22;
  while (data.getUint32(end, Endian.little) != endSignature) {
    end--;
  }
  var entry = data.getUint32(end + 16, Endian.little);
  while (data.getUint32(entry, Endian.little) == entrySignature) {
    bytes[entry + 5] = unix;
    final nameLength = data.getUint16(entry + 28, Endian.little);
    final extraLength = data.getUint16(entry + 30, Endian.little);
    final commentLength = data.getUint16(entry + 32, Endian.little);
    entry += 46 + nameLength + extraLength + commentLength;
  }
  return bytes;
}

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('raccoon_store'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('names the platform the way the bucket does', () {
    expect(RuntimeStore.platformFor('linux', Abi.linuxX64), 'linux-x64');
    expect(RuntimeStore.platformFor('linux', Abi.linuxArm64), 'linux-arm64');
    expect(RuntimeStore.platformFor('macos', Abi.macosArm64), 'darwin');
    expect(RuntimeStore.platformFor('macos', Abi.macosX64), 'darwin');
    expect(RuntimeStore.platformFor('windows', Abi.windowsX64), 'windows-x64');
    expect(
      () => RuntimeStore.platformFor('fuchsia', Abi.fuchsiaArm64),
      throwsUnsupportedError,
    );
  });

  test('artifact uri follows the bucket layout', () {
    expect(
      RuntimeStore.artifactUri('abc123', platform: 'linux-x64').toString(),
      'https://storage.googleapis.com/flutter_infra_release/flutter/abc123/linux-x64/linux-x64-embedder.zip',
    );
    expect(
      RuntimeStore.artifactUri('abc123', platform: 'darwin').toString(),
      'https://storage.googleapis.com/flutter_infra_release/flutter/abc123/darwin-x64/FlutterEmbedder.framework.zip',
    );
  });

  test('knows where each host keeps its library and icu data', () {
    expect(RuntimeStore.engineLibraryOf('linux-arm64'), 'libflutter_engine.so');
    expect(RuntimeStore.engineLibraryOf('windows-x64'), 'flutter_engine.dll');
    expect(
      RuntimeStore.engineLibraryOf('darwin'),
      p.join('FlutterEmbedder.framework', 'FlutterEmbedder'),
    );
    final engines = p.join('/sdk', 'bin', 'cache', 'artifacts', 'engine');
    expect(
      RuntimeStore.icuDataOfSdk('/sdk', platform: 'linux-x64'),
      p.join(engines, 'linux-x64', 'icudtl.dat'),
    );
    expect(
      RuntimeStore.icuDataOfSdk('/sdk', platform: 'darwin'),
      p.join(engines, 'darwin-x64', 'icudtl.dat'),
    );
    expect(
      RuntimeStore.icuDataOfSdk('/sdk', platform: 'windows-x64'),
      p.join(engines, 'windows-x64', 'icudtl.dat'),
    );
  });

  test('finds the home on Windows too, where HOME is seldom set', () {
    expect(RuntimeStore.homeOf({'HOME': '/h', 'USERPROFILE': 'C:/u'}), '/h');
    expect(
      RuntimeStore.homeOf({'USERPROFILE': r'C:\Users\me'}),
      r'C:\Users\me',
    );
    expect(
      RuntimeStore.forHost({'USERPROFILE': r'C:\Users\me'}).cacheDirectory,
      p.join(r'C:\Users\me', '.cache', 'raccoon', 'engines'),
    );
  });

  test('reads the engine revision from the sdk stamp', () {
    final sdk = Directory(p.join(temp.path, 'sdk', 'bin', 'cache'))
      ..createSync(recursive: true);
    File(p.join(sdk.path, 'engine.stamp')).writeAsStringSync('deadbeef\n');

    expect(RuntimeStore.revisionOfSdk(p.join(temp.path, 'sdk')), 'deadbeef');
    expect(RuntimeStore.revisionOfSdk(p.join(temp.path, 'nope')), isNull);
  });

  test(
    'ensure downloads, extracts and then finds the runtime installed',
    () async {
      final requested = <Uri>[];
      final store = RuntimeStore(
        cacheDirectory: p.join(temp.path, 'engines'),
        platform: 'linux-x64',
        download: (uri) async {
          requested.add(uri);
          return _linuxEmbedderZip();
        },
      );

      expect(store.installed('rev1'), isNull);
      final runtime = await store.ensure('rev1');

      expect(runtime.revision, 'rev1');
      expect(File(runtime.engineLibrary).existsSync(), isTrue);
      expect(
        File(runtime.embedderHeader).readAsStringSync(),
        contains('FLUTTER_ENGINE_VERSION'),
      );
      expect(store.installed('rev1')?.directory, runtime.directory);
      expect(requested, [
        RuntimeStore.artifactUri('rev1', platform: 'linux-x64'),
      ]);

      await store.ensure('rev1');
      expect(requested, hasLength(1), reason: 'no second download');
    },
  );

  test('ensure unpacks the macOS framework with its links', () async {
    final store = RuntimeStore(
      cacheDirectory: p.join(temp.path, 'engines'),
      platform: 'darwin',
      download: (_) async => _darwinEmbedderZip(),
    );

    final runtime = await store.ensure('rev1');

    expect(runtime.directory, endsWith(p.join('rev1', 'darwin')));
    expect(
      File(runtime.engineLibrary).resolveSymbolicLinksSync(),
      endsWith(p.join('Versions', 'A', 'FlutterEmbedder')),
    );
    expect(
      File(runtime.embedderHeader).readAsStringSync(),
      contains('FLUTTER_ENGINE_VERSION'),
    );
    expect(store.installed('rev1'), isNotNull);
  }, skip: Platform.isWindows ? 'symbolic links' : false);

  // #113: unpacking took the caller's isolate for 300 ms, the UI's in a
  // host.
  test('ensure unpacks without holding up the caller\'s isolate', () async {
    // Many files take a while to write, whatever the host: unpacked on the
    // caller's isolate they hold it far longer than handing them over does.
    var seed = 1;
    Uint8List noise(int length) {
      final bytes = Uint8List(length);
      for (var i = 0; i < length; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        bytes[i] = seed >> 16;
      }
      return bytes;
    }

    final library = noise(1 << 20);
    final archive =
        Archive()..addFile(ArchiveFile.bytes('libflutter_engine.so', library));
    for (var i = 0; i < 3000; i++) {
      archive.addFile(ArchiveFile.bytes('data/file_$i.bin', noise(4096)));
    }
    final zip = ZipEncoder().encodeBytes(archive);
    final store = RuntimeStore(
      cacheDirectory: temp.path,
      platform: 'linux-x64',
      download: (_) async => zip,
    );
    // The longest the caller's event loop went without a turn, against the
    // whole call: held up by the unpack, nearly all of it (460 of 470 ms on
    // an M1); on its own isolate, the handover alone (22 of 440). A ratio
    // holds on a slow host too, where counting turns did not (#137).
    final clock = Stopwatch()..start();
    var last = Duration.zero;
    var longest = Duration.zero;
    void turn() {
      final gap = clock.elapsed - last;
      if (gap > longest) longest = gap;
      last = clock.elapsed;
    }

    final timer = Timer.periodic(
      const Duration(milliseconds: 5),
      (_) => turn(),
    );
    final runtime = await store.ensure('big');
    turn();
    timer.cancel();
    expect(
      File(p.join(runtime.directory, 'libflutter_engine.so')).lengthSync(),
      library.length,
    );
    expect(longest * 2, lessThan(clock.elapsed));
  });

  test('overlapping ensures share one install', () async {
    var seed = 7;
    final library = Uint8List(8 << 20);
    for (var i = 0; i < library.length; i++) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      library[i] = seed >> 16;
    }
    var downloads = 0;
    final zip = ZipEncoder().encodeBytes(
      Archive()..addFile(ArchiveFile.bytes('libflutter_engine.so', library)),
    );
    final store = RuntimeStore(
      cacheDirectory: temp.path,
      platform: 'linux-x64',
      download: (_) async {
        downloads++;
        return zip;
      },
    );
    final runtimes = await Future.wait([
      store.ensure('twice'),
      store.ensure('twice'),
    ]);
    expect(downloads, 1);
    for (final runtime in runtimes) {
      expect(
        File(p.join(runtime.directory, 'libflutter_engine.so')).lengthSync(),
        library.length,
      );
    }
    expect(
      temp.listSync(recursive: true).where((e) => e.path.contains('.partial')),
      isEmpty,
    );
  });

  test('a store finishing second keeps the first one\'s install', () async {
    final zip = ZipEncoder().encodeBytes(
      Archive()
        ..addFile(ArchiveFile.bytes('libflutter_engine.so', [0x7f, 0x45])),
    );
    final first = RuntimeStore(
      cacheDirectory: temp.path,
      platform: 'linux-x64',
      download: (_) async => zip,
    );
    // The second store's download ends after the first store installed.
    final second = RuntimeStore(
      cacheDirectory: temp.path,
      platform: 'linux-x64',
      download: (_) async {
        final installed = await first.ensure('race');
        File(p.join(installed.directory, 'in-use')).writeAsStringSync('');
        return zip;
      },
    );
    final runtime = await second.ensure('race');
    expect(File(p.join(runtime.directory, 'in-use')).existsSync(), isTrue);
    expect(second.installed('race'), isNotNull);
  });

  test('a staging folder a killed install left is cleaned up', () async {
    final store = RuntimeStore(
      cacheDirectory: temp.path,
      platform: 'linux-x64',
      download:
          (_) async => ZipEncoder().encodeBytes(
            Archive()..addFile(
              ArchiveFile.bytes('libflutter_engine.so', [0x7f, 0x45]),
            ),
          ),
    );
    final directory = Directory(store.directoryFor('stale'));
    final left = Directory('${directory.path}.partialKILLED')
      ..createSync(recursive: true);
    // An hour ago and more: no install is still writing it.
    Process.runSync('touch', ['-t', '202001010000', left.path]);
    await store.ensure('stale');
    expect(left.existsSync(), isFalse);
  }, skip: Platform.isWindows ? 'touch -t is for Unix' : false);

  test('ensure rejects an archive without the engine library', () async {
    final store = RuntimeStore(
      cacheDirectory: p.join(temp.path, 'engines'),
      platform: 'linux-x64',
      download:
          (_) async => ZipEncoder().encodeBytes(
            Archive()..addFile(ArchiveFile.string('README', 'empty')),
          ),
    );

    expect(store.ensure('rev2'), throwsStateError);
  });

  // #134: a download that stalled held ensure() for good.
  test('a download that stalls fails', () async {
    final stalled = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(stalled.close);
    stalled.listen((socket) {
      socket.listen((_) {
        socket.write('HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\nabc');
      });
    });
    await expectLater(
      RuntimeStore.httpDownload(
        Uri.parse('http://127.0.0.1:${stalled.port}/engine.zip'),
        stallTimeout: const Duration(milliseconds: 300),
      ).timeout(const Duration(seconds: 5)),
      throwsA(
        isA<TimeoutException>().having(
          (e) => e.duration,
          'duration',
          const Duration(milliseconds: 300),
        ),
      ),
    );
  });
}

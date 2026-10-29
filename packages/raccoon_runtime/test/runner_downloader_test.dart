import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

import 'support/fake_release_server.dart';

void main() {
  late Directory temp;
  late FakeReleaseServer server;
  late RunnerDownloader downloader;
  late PrebuiltRunner prebuilt;

  final pinned = RunnerVersion.parse('0.3.0-pre.1') ?? (throw StateError(''));

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('raccoon_download');
    server = await FakeReleaseServer.start();
    downloader = RunnerDownloader(
      releases: server.releasesUri,
      platform: 'linux-x64',
    );
    prebuilt = PrebuiltRunner(p.join(temp.path, 'runtime', 'runner'));
  });

  tearDown(() async {
    await server.close();
    temp.deleteSync(recursive: true);
  });

  group('RunnerVersion', () {
    test('parses a version, a prerelease and a tag', () {
      final version = RunnerVersion.parse('0.3.0-pre.1');
      expect(version?.major, 0);
      expect(version?.minor, 3);
      expect(version?.text, '0.3.0-pre.1');
      expect(version?.series, '0.3.x');
      expect(RunnerVersion.parse('v1.2.3')?.text, '1.2.3');
      expect(RunnerVersion.parse('runner-v1.2.3')?.text, '1.2.3');
      expect(RunnerVersion.parse('runner-v1.2.3')?.series, '1.2.x');
      expect(RunnerVersion.parse(' 0.3.1\n')?.text, '0.3.1');
      expect(RunnerVersion.parse('latest'), isNull);
      expect(RunnerVersion.parse('0.3'), isNull);
    });

    test('is compatible within its major and minor', () {
      expect(
        pinned.isCompatibleWith(RunnerVersion.parse('0.3.4') ?? pinned),
        isTrue,
      );
      expect(
        pinned.isCompatibleWith(RunnerVersion.parse('0.4.0') ?? pinned),
        isFalse,
      );
      expect(
        pinned.isCompatibleWith(RunnerVersion.parse('1.3.0') ?? pinned),
        isFalse,
      );
    });

    test('orders prereleases, releases and patches', () {
      final ordered =
          [
            '0.2.9',
            '0.3.0-pre',
            '0.3.0-pre.1',
            '0.3.0-pre.2',
            '0.3.0-pre.10',
            '0.3.0-pre.x',
            '0.3.0-rc.1',
            '0.3.0',
            '0.3.1',
            '1.0.0',
          ].map((text) => RunnerVersion.parse(text) ?? pinned).toList();
      for (var i = 0; i < ordered.length; i++) {
        for (var j = 0; j < ordered.length; j++) {
          expect(
            ordered[i].isOlderThan(ordered[j]),
            i < j,
            reason: '${ordered[i]} before ${ordered[j]}',
          );
        }
      }
      expect(
        pinned.isOlderThan(RunnerVersion.parse('0.3.0-pre.1+build') ?? pinned),
        isFalse,
      );
    });

    test('reads a VERSION file', () {
      final file = File(p.join(temp.path, 'VERSION'))
        ..writeAsStringSync('0.3.2\n');
      expect(RunnerVersion.read(file.path), RunnerVersion.parse('0.3.2'));
      expect(RunnerVersion.read(p.join(temp.path, 'missing')), isNull);
    });
  });

  test('names the archive for the host', () {
    expect(RunnerDownloader.platformFor('linux', Abi.linuxX64), 'linux-x64');
    expect(
      RunnerDownloader.platformFor('macos', Abi.macosArm64),
      'macos-arm64',
    );
    expect(RunnerDownloader.platformFor('macos', Abi.macosX64), 'macos-x64');
    expect(
      RunnerDownloader.assetName(pinned, 'linux-x64'),
      'raccoon_runner-0.3.0-pre.1-linux-x64.tar.gz',
    );
  });

  test(
    'picks the newest compatible release with an archive for the host',
    () async {
      server
        ..addRelease('runner-v0.4.0', platforms: ['linux-x64'])
        ..addRelease('runner-v0.3.3', platforms: ['linux-x64'], draft: true)
        ..addRelease('runner-v0.3.2', platforms: ['macos-arm64'])
        ..addRelease(
          'runner-v0.3.1',
          platforms: ['linux-x64', 'macos-arm64'],
          prerelease: true,
        )
        ..addRelease('runner-v0.3.0', platforms: ['linux-x64'])
        ..addRelease('runner-v0.2.0', platforms: ['linux-x64']);

      final release = await downloader.find(pinned);

      expect(release?.version, RunnerVersion.parse('0.3.1'));
      expect(release?.prerelease, isTrue);
      expect(
        release?.asset.path,
        endsWith('raccoon_runner-0.3.1-linux-x64.tar.gz'),
      );
    },
  );

  test('picks the highest version, not the latest published', () async {
    server
      ..addRelease('runner-v0.3.1', platforms: ['linux-x64'])
      ..addRelease('runner-v0.3.2', platforms: ['linux-x64'])
      ..addRelease('runner-v0.3.0', platforms: ['linux-x64']);

    final release = await downloader.find(pinned);

    expect(release?.version, RunnerVersion.parse('0.3.2'));
  });

  test('a release pin takes no prerelease', () async {
    server
      ..addRelease('runner-v0.3.2-pre.1', platforms: ['linux-x64'])
      ..addRelease('runner-v0.3.1', platforms: ['linux-x64']);
    final stable = RunnerVersion.parse('0.3.0') ?? pinned;

    expect(
      (await downloader.find(stable))?.version,
      RunnerVersion.parse('0.3.1'),
    );
  });

  test('skips the protocol package\'s own v tags', () async {
    server
      // The protocol package's release carries runner-like assets here on
      // purpose: the tag alone must rule it out.
      ..addRelease('v0.7.0', platforms: ['linux-x64'])
      ..addRelease('runner-v0.3.1', platforms: ['linux-x64']);

    final release = await downloader.find(pinned);

    expect(release?.version, RunnerVersion.parse('0.3.1'));
    expect(
      release?.asset.path,
      endsWith('raccoon_runner-0.3.1-linux-x64.tar.gz'),
    );
  });

  test('skips a release older than the pin', () async {
    server.addRelease('runner-v0.3.0-pre.1', platforms: ['linux-x64']);
    final newer = RunnerVersion.parse('0.3.0-pre.2') ?? pinned;

    expect(await downloader.find(newer), isNull);
  });

  test('finds nothing without a compatible release for the host', () async {
    server
      ..addRelease('runner-v0.4.0', platforms: ['linux-x64'])
      ..addRelease('runner-v0.3.0', platforms: ['macos-arm64']);

    expect(await downloader.find(pinned), isNull);
  });

  test('unpacks the archive into the runtime directory, executable', () async {
    server.addRelease(
      'runner-v0.3.1',
      platforms: ['linux-x64'],
      archive: fakeRunnerArchive(version: '0.3.1'),
    );
    // Whatever an earlier download left goes away.
    File(p.join(prebuilt.directory, 'stale'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('old');
    final release =
        await downloader.find(pinned) ?? (throw StateError('no release'));

    await downloader.install(release, prebuilt);

    expect(
      RunnerVersion.read(prebuilt.versionFile),
      RunnerVersion.parse('0.3.1'),
    );
    expect(File(prebuilt.deviceHelper).existsSync(), isTrue);
    expect(
      File(p.join(prebuilt.directory, 'tool', 'engine_dir.sh')).existsSync(),
      isTrue,
    );
    expect(File(p.join(prebuilt.directory, 'stale')).existsSync(), isFalse);
    expect(
      Directory(p.dirname(prebuilt.directory))
          .listSync()
          .map((entry) => p.basename(entry.path))
          .where((name) => name.contains('.partial')),
      isEmpty,
    );
    final ran = await _runScript(prebuilt.binary);
    expect(ran.stdout, 'raccoon_runner 0.3.1\n');
    final ping = await _runScript(prebuilt.deviceHelper);
    expect(ping.stdout, 'ping\n');
  });

  test('deletes a runner an earlier install moved aside', () async {
    server.addRelease(
      'runner-v0.3.1',
      platforms: ['linux-x64'],
      archive: fakeRunnerArchive(version: '0.3.1'),
    );
    final aside = Directory('${prebuilt.directory}.old-1-2')
      ..createSync(recursive: true);
    File(p.join(aside.path, 'held')).writeAsStringSync('old');
    Directory(prebuilt.directory).createSync(recursive: true);
    final release =
        await downloader.find(pinned) ?? (throw StateError('no release'));

    await downloader.install(release, prebuilt);

    expect(File(prebuilt.binary).existsSync(), isTrue);
    expect(
      Directory(
        p.dirname(prebuilt.directory),
      ).listSync().map((entry) => p.basename(entry.path)),
      ['runner'],
    );
  });

  test('leaves an entry that would escape the directory out', () async {
    server.addRelease(
      'runner-v0.3.1',
      platforms: ['linux-x64'],
      archive: fakeRunnerArchive(entries: {'../escaped': 'no'}),
    );
    final release =
        await downloader.find(pinned) ?? (throw StateError('no release'));

    await downloader.install(release, prebuilt);

    expect(File(p.join(temp.path, 'runtime', 'escaped')).existsSync(), isFalse);
    expect(File(prebuilt.binary).existsSync(), isTrue);
  });

  test('refuses an archive without the binary', () async {
    server.addRelease(
      'runner-v0.3.1',
      platforms: ['linux-x64'],
      archive: fakeRunnerArchive(withBinary: false),
    );
    final release =
        await downloader.find(pinned) ?? (throw StateError('no release'));

    await expectLater(
      downloader.install(release, prebuilt),
      throwsA(
        isA<DownloadFailed>().having(
          (e) => e.message,
          'message',
          contains('No raccoon_runner'),
        ),
      ),
    );
    expect(Directory(prebuilt.directory).existsSync(), isFalse);
    expect(
      Directory(p.dirname(prebuilt.directory))
          .listSync()
          .map((entry) => p.basename(entry.path))
          .where((name) => name.contains('.partial')),
      isEmpty,
    );
  });

  test('refuses something that is not an archive', () async {
    server.addRelease(
      'runner-v0.3.1',
      platforms: ['linux-x64'],
      archive: [1, 2, 3],
    );
    final release =
        await downloader.find(pinned) ?? (throw StateError('no release'));

    await expectLater(
      downloader.install(release, prebuilt),
      throwsA(
        isA<DownloadFailed>().having(
          (e) => e.message,
          'message',
          contains('not a tar.gz'),
        ),
      ),
    );
  });

  test('reports a missing archive', () async {
    server.addRelease('runner-v0.3.1', platforms: ['linux-x64']);
    final release =
        await downloader.find(pinned) ?? (throw StateError('no release'));

    await expectLater(
      downloader.install(release, prebuilt),
      throwsA(
        isA<DownloadFailed>().having(
          (e) => e.message,
          'message',
          contains('404'),
        ),
      ),
    );
  });

  // #132: a download that stalled kept setup waiting for good.
  test('a download that stalls fails instead of waiting for good', () async {
    final stalled = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(stalled.close);
    stalled.listen((socket) {
      socket.listen((_) {
        // Headers and the start of the body, then nothing more.
        socket.write('HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\nabc');
      });
    });
    final slow = RunnerDownloader(
      releases: Uri.parse('http://127.0.0.1:${stalled.port}/releases'),
      platform: 'linux-x64',
      stallTimeout: const Duration(milliseconds: 300),
    );
    await expectLater(
      slow.find(pinned).timeout(const Duration(seconds: 5)),
      throwsA(
        isA<DownloadFailed>().having(
          (e) => e.message,
          'message',
          contains('nothing came'),
        ),
      ),
    );
  });

  test('reports a list that cannot be fetched or read', () async {
    final elsewhere = RunnerDownloader(
      releases: server.releasesUri.replace(path: '/nowhere'),
      platform: 'linux-x64',
    );
    await expectLater(elsewhere.find(pinned), throwsA(isA<DownloadFailed>()));

    await server.close();
    await expectLater(downloader.find(pinned), throwsA(isA<DownloadFailed>()));
  });

  test('reports a list that is not JSON, or not a list', () async {
    server.releasesBody = '<html>';
    await expectLater(
      downloader.find(pinned),
      throwsA(
        isA<DownloadFailed>().having(
          (error) => error.message,
          'message',
          contains('did not answer with JSON'),
        ),
      ),
    );
    server.releasesBody = '{"message": "Not Found"}';
    await expectLater(
      downloader.find(pinned),
      throwsA(
        isA<DownloadFailed>().having(
          (error) => error.message,
          'message',
          contains('did not answer with a list of releases'),
        ),
      ),
    );
  });

  test('the current version is the runner\'s VERSION', () {
    final file = p.join(
      Directory.current.path,
      '..',
      '..',
      'native',
      'raccoon_runner',
      'VERSION',
    );
    expect(RunnerVersion.read(file)?.text, RunnerVersion.current);
  });

  test('a prebuilt runner has a version only with its binary and helper', () {
    expect(prebuilt.version, isNull);
    File(prebuilt.versionFile)
      ..createSync(recursive: true)
      ..writeAsStringSync('0.3.0-pre.5\n');
    expect(prebuilt.version, isNull);
    File(prebuilt.binary).createSync();
    // Half unpacked: no device helper, no runner.
    expect(prebuilt.version, isNull);
    File(prebuilt.deviceHelper).createSync(recursive: true);
    expect(prebuilt.version?.text, '0.3.0-pre.5');
  });

  test('an archive whose SHA-256 is not the release\'s is refused', () async {
    final archive = fakeRunnerArchive(version: '0.3.1');
    server.addRelease(
      'runner-v0.3.1',
      platforms: ['linux-x64'],
      archive: archive,
      digest: 'sha256:${sha256.convert([...archive, 0])}',
    );
    final release =
        await downloader.find(pinned) ?? (throw StateError('no release'));
    await expectLater(
      downloader.install(release, prebuilt),
      throwsA(isA<DownloadFailed>()),
    );
    expect(prebuilt.version, isNull);
  });

  test('an archive whose SHA-256 is the release\'s installs', () async {
    final archive = fakeRunnerArchive(version: '0.3.1');
    server.addRelease(
      'runner-v0.3.1',
      platforms: ['linux-x64'],
      archive: archive,
      digest: 'sha256:${sha256.convert(archive)}',
    );
    final release =
        await downloader.find(pinned) ?? (throw StateError('no release'));
    expect(release.sha256, '${sha256.convert(archive)}');
    await downloader.install(release, prebuilt);
    expect(prebuilt.version?.text, '0.3.1');
  });

  test(
    'an archive cut short is refused, not unpacked into fewer files',
    () async {
      final archive = fakeRunnerArchive(
        version: '0.3.1',
        entries: {'LICENSE': 'x' * 40000},
      );
      server.addRelease(
        'runner-v0.3.1',
        platforms: ['linux-x64'],
        archive: archive.sublist(0, archive.length * 9 ~/ 10),
      );
      final release =
          await downloader.find(pinned) ?? (throw StateError('no release'));
      await expectLater(
        downloader.install(release, prebuilt),
        throwsA(isA<DownloadFailed>()),
      );
      expect(prebuilt.version, isNull);
    },
  );

  test(
    'installs at the same moment each leave a whole runner',
    () async {
      server.addRelease(
        'runner-v0.3.1',
        platforms: ['linux-x64'],
        archive: fakeRunnerArchive(version: '0.3.1'),
      );
      final release =
          await downloader.find(pinned) ?? (throw StateError('no release'));
      for (var round = 0; round < 5; round++) {
        await Future.wait([
          for (var i = 0; i < 3; i++)
            downloader
                .install(release, prebuilt)
                .catchError(
                  (Object error) => expect(error, isA<DownloadFailed>()),
                ),
        ]);
        expect(prebuilt.version?.text, '0.3.1', reason: 'round $round');
        expect(
          File(
            p.join(prebuilt.directory, 'tool', 'engine_dir.sh'),
          ).existsSync(),
          isTrue,
          reason: 'round $round',
        );
      }
      // No half-unpacked folder left beside it. A runner moved aside may be
      // (Windows won't delete a folder another install still has a file of
      // open); a later install deletes it.
      expect(
        Directory(p.dirname(prebuilt.directory))
            .listSync()
            .map((entry) => p.basename(entry.path))
            .where(
              (name) => name != 'runner' && !name.startsWith('runner.old-'),
            ),
        isEmpty,
      );
    },
    // Concurrent renames of one folder kept failing there on CI for the
    // whole retry, three installs at once (#271): for a Windows machine.
    skip: switch (Platform.isWindows) {
      true => 'concurrent installs on Windows want a look on a real machine',
      false => false,
    },
  );
}

/// Runs one of the archive's stand-in scripts: by its executable bit, or on
/// Windows, which has none, through Git Bash as the device helper is.
Future<ProcessResult> _runScript(String path) => switch (CustomDeviceConfig
    .hostLauncher) {
  [final shell] => Process.run(shell, [path]),
  _ => Process.run(path, const []),
};

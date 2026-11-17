// Drives the real runner: pointers, keys, text input and semantics reach the
// app. Skipped when the runner or its inputs are not built; see
// native/raccoon_runner/tool/render_example.sh. What the files share is in
// test/support/runner_fixture.dart.

import 'dart:async';
import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:path/path.dart' as p;
import 'package:raccoon/raccoon.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

import '../support/runner_fixture.dart';

// The fixture's helpers, by the names these tests have always used.
const _red = red;
const _white = white;
const _pixel = pixel;
const _expectExit = expectExit;

void main() {
  final RunnerFixture(
    :binary,
    :assets,
    :engineDir,
    :icu,
    :ready,
    :viewsAssets,
  ) = RunnerFixture();
  test(
    'taps as a finger reach the app, each press a pointer of its own',
    () async {
      // #207: a view sends the mouse as a finger: down, up, then gone, a
      // new pointer every press. example/views' box turns white on a tap,
      // and red on the next.
      final temp = Directory.systemTemp.createTempSync('raccoon_touch');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: viewsAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
          width: 390,
          height: 300,
          views: true,
        ),
      );
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        await client.frames.first.timeout(const Duration(seconds: 15));
        Future<void> tap(int pointer, ({int r, int g, int b}) colour) async {
          for (final (phase, buttons) in [
            (PointerPhase.POINTER_PHASE_DOWN, 1),
            (PointerPhase.POINTER_PHASE_UP, 0),
            (PointerPhase.POINTER_PHASE_REMOVE, 0),
          ]) {
            client.sendPointer(
              PointerEvent(
                phase: phase,
                x: 195,
                y: 150,
                buttons: Int64(buttons),
                device: PointerDevice.POINTER_DEVICE_TOUCH,
                pointerId: pointer,
              ),
            );
          }
          await client.frames
              .firstWhere((f) => _pixel(f, 195, 150) == colour)
              .timeout(const Duration(seconds: 10));
        }

        await tap(1, _white);
        await tap(2, _red);
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready && Directory(viewsAssets).existsSync()
            ? false
            : 'build the runner and example/views first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'keys reach the framework and typed characters reach a text field',
    () async {
      // example/text prints KEY:<event> for every key the framework
      // dispatches and TEXT:<value> for every change of its field.
      final textAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'text',
        'build',
        'flutter_assets',
      );
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: textAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      runner.stderr.listen(output.add);
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.frames.first.timeout(const Duration(seconds: 15));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        Future<void> key(int logical, int physical, String character) async {
          for (final kind in [KeyKind.KEY_KIND_DOWN, KeyKind.KEY_KIND_UP]) {
            client.sendKey(
              KeyEvent(
                kind: kind,
                physical: Int64(physical),
                logical: Int64(logical),
                character: kind == KeyKind.KEY_KIND_DOWN ? character : '',
                timestampMicros: Int64(DateTime.now().microsecondsSinceEpoch),
              ),
            );
            await Future<void>.delayed(const Duration(milliseconds: 60));
          }
        }

        await key(0x68, 0x0007000b, 'h');
        await key(0x69, 0x0007000c, 'i');
        // Backspace is the framework's: its shortcut deletes, not the runner.
        await key(0x100000008, 0x0007002a, '');
        // Typed only once the field shows the deletion: the framework sends
        // the edited text after its frame, which a slow host may not have
        // drawn 60 ms on, and a key before it edits the text before it.
        final deleted = DateTime.now().add(const Duration(seconds: 10));
        while (output
                    .where((line) => line.trimRight().endsWith('TEXT:h'))
                    .length <
                2 &&
            DateTime.now().isBefore(deleted)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await key(0x79, 0x0007001c, 'y');
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!output.any((line) => line.contains('TEXT:hy')) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final text =
            output
                .where((line) => line.contains('TEXT:'))
                .map((line) => line.substring(line.indexOf('TEXT:')))
                .toList();
        expect(text, ['TEXT:h', 'TEXT:hi', 'TEXT:h', 'TEXT:hy']);
        expect(
          output.where((line) => line.contains('KEY:KeyDownEvent')).length,
          4,
        );
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready &&
                Directory(
                  p.join(
                    p.dirname(p.dirname(p.dirname(assets))),
                    'text',
                    'build',
                    'flutter_assets',
                  ),
                ).existsSync()
            ? false
            : 'build the runner and the text example first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'semantics find widgets by test id, with their bounds, and act on them',
    () async {
      // example/semantics: a counter and a text field with test ids, each
      // change printed (COUNT n, TEXT t). At a pixel ratio of 2 the app's
      // left padding of 100 is 200 pixels.
      final semanticsAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'semantics',
        'build',
        'flutter_assets',
      );
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: semanticsAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      runner.stderr.listen(output.add);
      final client = await RunnerClient.connect(endpoint);
      Future<void> printed(String line) async {
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!output.any((out) => out.contains(line)) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(output.any((out) => out.contains(line)), isTrue, reason: line);
      }

      SemanticsNode byId(List<SemanticsNode> nodes, String id) =>
          nodes.firstWhere((node) => node.identifier == id);
      try {
        await client.hello.timeout(const Duration(seconds: 10));
        expect(client.takesSemantics, isTrue);
        client.resize(1000, 800, 2);
        await client.frames.first.timeout(const Duration(seconds: 15));

        var nodes = await client.semantics(
          keepOn: const Duration(seconds: 2),
          timeout: const Duration(seconds: 10),
        );
        expect(nodes.first.id, 0);
        expect(nodes.first.right, closeTo(1000, 0.5));
        expect(nodes.first.bottom, closeTo(800, 0.5));
        final count = byId(nodes, 'count');
        expect(count.label, 'Count 0');
        expect(count.left, closeTo(200, 0.5));
        expect(count.top, closeTo(100, 0.5));
        // The id wraps the button, a node of its own that takes the tap.
        final increment = byId(nodes, 'increment');
        expect(increment.left, closeTo(200, 0.5));
        expect(increment.right - increment.left, closeTo(400, 0.5));
        final button = nodes.firstWhere(
          (node) => node.id == increment.children.single,
        );
        expect(button.label, 'Increment');
        expect(SemanticsNodeFlag.isButton.isOn(button), isTrue);
        expect(SemanticsNodeAction.tap.isOn(button), isTrue);

        client.performSemanticsAction(button.id, SemanticsNodeAction.tap);
        await printed('COUNT 1');
        nodes = await client.semantics(keepOn: const Duration(seconds: 2));
        expect(byId(nodes, 'count').label, 'Count 1');

        // A field takes text only while it has the focus.
        final field = byId(nodes, 'name');
        expect(SemanticsNodeFlag.isTextField.isOn(field), isTrue);
        client.performSemanticsAction(field.id, SemanticsNodeAction.tap);
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!SemanticsNodeAction.setText.isOn(byId(nodes, 'name')) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          nodes = await client.semantics(keepOn: const Duration(seconds: 2));
        }
        client.performSemanticsAction(
          field.id,
          SemanticsNodeAction.setText,
          text: 'raccoon',
        );
        await printed('TEXT raccoon');

        // Two seconds with no ask turn semantics off.
        await printed('semantics off');
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready &&
                Directory(
                  p.join(
                    p.dirname(p.dirname(p.dirname(assets))),
                    'semantics',
                    'build',
                    'flutter_assets',
                  ),
                ).existsSync()
            ? false
            : 'build the runner and the semantics example first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  // raccoon#298: Flutter takes no key without both codes, and a debug app
  // asserted on each one a client sent.
  test(
    'a key with no code is dropped, and the next one still types',
    () async {
      final textAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'text',
        'build',
        'flutter_assets',
      );
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: textAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      runner.stderr.listen(output.add);
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.frames.first.timeout(const Duration(seconds: 15));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        for (final (logical, physical, character) in [
          (0, 0x0007000b, 'x'),
          (0x68, 0, 'x'),
          (0x68, 0x0007000b, 'h'),
        ]) {
          for (final kind in [KeyKind.KEY_KIND_DOWN, KeyKind.KEY_KIND_UP]) {
            client.sendKey(
              KeyEvent(
                kind: kind,
                physical: Int64(physical),
                logical: Int64(logical),
                character: kind == KeyKind.KEY_KIND_DOWN ? character : '',
                timestampMicros: Int64(DateTime.now().microsecondsSinceEpoch),
              ),
            );
            await Future<void>.delayed(const Duration(milliseconds: 60));
          }
        }
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!output.any((line) => line.contains('TEXT:h')) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final all = output.join();
        expect(all, contains('TEXT:h'));
        expect(all, isNot(contains('TEXT:x')));
        expect(all, isNot(contains('Failed assertion')));
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready &&
                Directory(
                  p.join(
                    p.dirname(p.dirname(p.dirname(assets))),
                    'text',
                    'build',
                    'flutter_assets',
                  ),
                ).existsSync()
            ? false
            : 'build the runner and the text example first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'the deprecated RawKeyboard tells keys apart and keeps a modifier held '
    'on either side',
    () async {
      // example/text prints RAW:<type>:<physical>:<pressed>:<shift>:<control>
      // for every RawKeyboard event; physical keys are HID usages in hex.
      final textAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'text',
        'build',
        'flutter_assets',
      );
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: textAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      runner.stderr.listen(output.add);
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.frames.first.timeout(const Duration(seconds: 15));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        Future<void> send(
          KeyKind kind,
          int logical,
          int physical, [
          String character = '',
        ]) async {
          client.sendKey(
            KeyEvent(
              kind: kind,
              physical: Int64(physical),
              logical: Int64(logical),
              character: character,
              timestampMicros: Int64(DateTime.now().microsecondsSinceEpoch),
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 60));
        }

        const down = KeyKind.KEY_KIND_DOWN;
        const up = KeyKind.KEY_KIND_UP;
        // A down, B down, A up: B is still held.
        await send(down, 0x61, 0x00070004, 'a');
        await send(down, 0x62, 0x00070005, 'b');
        await send(up, 0x61, 0x00070004);
        await send(up, 0x62, 0x00070005);
        // Both Shifts down, the left one up: Shift is still held.
        await send(down, 0x200000102, 0x000700e1);
        await send(down, 0x200000103, 0x000700e5);
        await send(up, 0x200000102, 0x000700e1);
        await send(down, 0x63, 0x00070006, 'C');
        await send(up, 0x63, 0x00070006);
        await send(up, 0x200000103, 0x000700e5);
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        bool done() =>
            output.any((line) => line.contains('RAW:RawKeyUpEvent:700e5:'));
        while (!done() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final raw =
            output
                .where((line) => line.contains('RAW:'))
                .map((line) => line.substring(line.indexOf('RAW:')))
                .toList();
        printOnFailure(raw.join('\n'));
        String event(String type, String physical) =>
            raw.firstWhere((line) => line.startsWith('RAW:$type:$physical:'));
        final aUp = event('RawKeyUpEvent', '70004').split(':')[3].split(',');
        expect(aUp, contains('70005'));
        expect(aUp, isNot(contains('70004')));
        final cDown = event('RawKeyDownEvent', '70006').split(':');
        expect(cDown[3].split(','), contains('70006'));
        expect(cDown.sublist(4), ['true', 'false']);
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready &&
                Directory(
                  p.join(
                    p.dirname(p.dirname(p.dirname(assets))),
                    'text',
                    'build',
                    'flutter_assets',
                  ),
                ).existsSync()
            ? false
            : 'build the runner and the text example first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'on a Mac, editing keys reach the field as AppKit selectors',
    () async {
      // A Mac app's framework leaves Option, Cmd and arrow keys in a text
      // field to the platform and waits for performSelectors.
      final textAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'text',
        'build',
        'flutter_assets',
      );
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: textAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      runner.stderr.listen(output.add);
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.frames.first.timeout(const Duration(seconds: 15));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        Future<void> send(KeyKind kind, int logical, int physical, String c) {
          client.sendKey(
            KeyEvent(
              kind: kind,
              physical: Int64(physical),
              logical: Int64(logical),
              character: c,
              timestampMicros: Int64(DateTime.now().microsecondsSinceEpoch),
            ),
          );
          return Future<void>.delayed(const Duration(milliseconds: 60));
        }

        Future<void> key(int logical, int physical, [String c = '']) async {
          await send(KeyKind.KEY_KIND_DOWN, logical, physical, c);
          await send(KeyKind.KEY_KIND_UP, logical, physical, '');
        }

        // A key with a modifier held: (logical, physical) pairs.
        Future<void> held((int, int) modifier, (int, int) pressed) async {
          await send(KeyKind.KEY_KIND_DOWN, modifier.$1, modifier.$2, '');
          await key(pressed.$1, pressed.$2);
          await send(KeyKind.KEY_KIND_UP, modifier.$1, modifier.$2, '');
        }

        await key(0x61, 0x00070004, 'a');
        await key(0x62, 0x00070005, 'b');
        await key(0x20, 0x0007002c, ' ');
        await key(0x63, 0x00070006, 'c');
        await key(0x64, 0x00070007, 'd');
        // Option+Backspace deletes the word, Cmd+Left goes to the line's
        // start.
        await held((0x200000104, 0x000700e2), (0x100000008, 0x0007002a));
        await held((0x200000106, 0x000700e3), (0x100000302, 0x00070050));
        await key(0x78, 0x0007001b, 'x');
        // Ctrl+H deletes back, AppKit's Emacs key that Flutter leaves to it.
        await held((0x200000100, 0x000700e0), (0x68, 0x0007000b));
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (output.where((line) => line.contains('TEXT:')).length < 8 &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final text =
            output
                .where((line) => line.contains('TEXT:'))
                .map((line) => line.substring(line.indexOf('TEXT:')))
                .toList();
        expect(text, [
          'TEXT:a',
          'TEXT:ab',
          'TEXT:ab ',
          'TEXT:ab c',
          'TEXT:ab cd',
          'TEXT:ab ',
          'TEXT:xab ',
          'TEXT:ab ',
        ]);
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch (ready &&
        Directory(
          p.join(
            p.dirname(p.dirname(p.dirname(assets))),
            'text',
            'build',
            'flutter_assets',
          ),
        ).existsSync()) {
      false => 'build the runner and the text example first',
      true when !Platform.isMacOS => 'AppKit selectors are a Mac app\'s',
      true => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'Alt picks a character on a Mac (Option) only, not elsewhere',
    () async {
      // Option types what the key gives on a Mac; elsewhere Alt with a
      // letter is a shortcut nobody took, and GTK and Windows type nothing.
      final textAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'text',
        'build',
        'flutter_assets',
      );
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: textAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      runner.stderr.listen(output.add);
      final client = await RunnerClient.connect(endpoint);
      try {
        await client.frames.first.timeout(const Duration(seconds: 15));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        Future<void> send(KeyKind kind, int logical, int physical, String c) {
          client.sendKey(
            KeyEvent(
              kind: kind,
              physical: Int64(physical),
              logical: Int64(logical),
              character: c,
              timestampMicros: Int64(DateTime.now().microsecondsSinceEpoch),
            ),
          );
          return Future<void>.delayed(const Duration(milliseconds: 60));
        }

        Future<void> key(int logical, int physical, [String c = '']) async {
          await send(KeyKind.KEY_KIND_DOWN, logical, physical, c);
          await send(KeyKind.KEY_KIND_UP, logical, physical, '');
        }

        await key(0x61, 0x00070004, 'a');
        // Alt+F, the character as the host reports it: Option gives ƒ.
        await send(KeyKind.KEY_KIND_DOWN, 0x200000104, 0x000700e2, '');
        await key(0x66, 0x00070009, Platform.isMacOS ? 'ƒ' : 'f');
        await send(KeyKind.KEY_KIND_UP, 0x200000104, 0x000700e2, '');
        await key(0x62, 0x00070005, 'b');
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        final last = Platform.isMacOS ? 'TEXT:aƒb' : 'TEXT:ab';
        while (!output.any((line) => line.contains(last)) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final text =
            output
                .where((line) => line.contains('TEXT:'))
                .map((line) => line.substring(line.indexOf('TEXT:')))
                .toList();
        expect(
          text,
          Platform.isMacOS
              ? ['TEXT:a', 'TEXT:aƒ', 'TEXT:aƒb']
              : ['TEXT:a', 'TEXT:ab'],
        );
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip: switch (ready &&
        Directory(
          p.join(
            p.dirname(p.dirname(p.dirname(assets))),
            'text',
            'build',
            'flutter_assets',
          ),
        ).existsSync()) {
      false => 'build the runner and the text example first',
      true => false,
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'a composing client mirrors the active field and types through it',
    () async {
      final textAssets = p.join(
        p.dirname(p.dirname(p.dirname(assets))),
        'text',
        'build',
        'flutter_assets',
      );
      final temp = Directory.systemTemp.createTempSync('raccoon_test');
      final endpoint = UnixSocketEndpoint(p.join(temp.path, 'runner.sock'));
      final runner = await RunnerProcess.start(
        RunnerLaunch(
          runnerBinary: binary ?? '',
          engineDir: engineDir ?? '',
          assets: textAssets,
          icuData: icu ?? '',
          endpoint: endpoint,
        ),
      );
      final output = <String>[];
      runner.stdout.listen(output.add);
      runner.stderr.listen(output.add);
      final client = await RunnerClient.connect(endpoint, composes: true);
      try {
        // The field has autofocus: its state arrives as it becomes active.
        final field = await client.textFields
            .firstWhere((field) => field.active)
            .timeout(const Duration(seconds: 15));
        expect(field.text, '');
        expect(field.multiline, isFalse);
        // Waits for the whole list: 'TEXT:tiếng' contains 'TEXT:tiến', so
        // waiting for a line with the last one ended before it came.
        Future<void> texts(List<String> expected) async {
          List<String> seen() => [
            for (final line in output)
              if (line.contains('TEXT:')) line.substring(line.indexOf('TEXT:')),
          ];
          final wanted = [for (final text in expected) 'TEXT:$text'];
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          while (seen().length < wanted.length &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(seen(), wanted);
        }

        // The host's input method composes "tiế", then commits "tiếng".
        client.sendTextEditing(
          TextEditing(
            text: 'tiế',
            selectionBase: 3,
            selectionExtent: 3,
            composingBase: 0,
            composingExtent: 3,
          ),
        );
        await texts(['tiế']);
        client.sendTextEditing(
          TextEditing(
            text: 'tiếng',
            selectionBase: 5,
            selectionExtent: 5,
            composingBase: -1,
            composingExtent: -1,
          ),
        );
        await texts(['tiế', 'tiếng']);
        final mirrored = await client.textFields
            .firstWhere((field) => field.text == 'tiếng')
            .timeout(const Duration(seconds: 5));
        expect(mirrored.selectionBase, 5);
        expect(mirrored.composingBase, -1);

        // A character key types nothing for a composing client; Backspace is
        // still the framework's.
        Future<void> key(int logical, int physical, String character) async {
          for (final kind in [KeyKind.KEY_KIND_DOWN, KeyKind.KEY_KIND_UP]) {
            client.sendKey(
              KeyEvent(
                kind: kind,
                physical: Int64(physical),
                logical: Int64(logical),
                character: kind == KeyKind.KEY_KIND_DOWN ? character : '',
                timestampMicros: Int64(DateTime.now().microsecondsSinceEpoch),
              ),
            );
            await Future<void>.delayed(const Duration(milliseconds: 60));
          }
        }

        await key(0x78, 0x0007001b, 'x');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await key(0x100000008, 0x0007002a, '');
        await texts(['tiế', 'tiếng', 'tiến']);
      } finally {
        client.shutdown();
        await client.close();
        await _expectExit(runner);
        temp.deleteSync(recursive: true);
      }
    },
    skip:
        ready &&
                Directory(
                  p.join(
                    p.dirname(p.dirname(p.dirname(assets))),
                    'text',
                    'build',
                    'flutter_assets',
                  ),
                ).existsSync()
            ? false
            : 'build the runner and the text example first',
    timeout: const Timeout(Duration(minutes: 2)),
  );
  // Built beside the runner: the semantics tree it keeps for clients
  // (test/semantics_check.cc).
  final semanticsCheck =
      binary == null
          ? ''
          : p.join(
            p.dirname(binary),
            Platform.isWindows
                ? 'raccoon_semantics_check.exe'
                : 'raccoon_semantics_check',
          );
  test(
    'the semantics tree merges updates and places nodes in the view',
    () async {
      final check = await Process.run(semanticsCheck, const []);
      printOnFailure('${check.stdout}${check.stderr}');
      expect(check.exitCode, 0);
      expect('${check.stdout}', contains('SEMANTICS ok'));
    },
    skip:
        File(semanticsCheck).existsSync()
            ? false
            : 'build the runner\'s semantics check first',
  );
}

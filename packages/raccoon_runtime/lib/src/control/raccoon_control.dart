import 'dart:async';
import 'dart:convert';

import 'package:raccoon_runtime/src/control/control_host.dart';
import 'package:raccoon_runtime/src/device_input.dart';
import 'package:raccoon_runtime/src/frame_capture.dart';
import 'package:raccoon_runtime/src/frame_image.dart';
import 'package:raccoon_runtime/src/raccoon_test_device.dart';
import 'package:raccoon_runtime/src/runner_discovery.dart';
import 'package:raccoon_runtime/src/runner_log.dart';

/// Something that takes control calls: a [RaccoonControl] in this process,
/// or a [RaccoonControlClient] to a host's endpoint.
abstract interface class RaccoonControlCalls {
  /// Calls [method] with [params]; the result as JSON. Throws a
  /// [RaccoonControlError] when the call fails.
  Future<Map<String, Object?>> call(String method, Map<String, Object?> params);
}

/// The control calls over a [RaccoonControlHost]: what an agent's tools
/// do to a host's devices, the same whichever host serves them. Input and
/// screenshots go through the host's own connection to each runner, so
/// the host shows all of it.
///
/// Every call but `list_devices` and `run` points at an app by `device`
/// (`raccoon-phone`, or just `phone`) and, when several apps run there, by
/// `app` (the project's name); with one app running anywhere, neither is
/// needed. Coordinates are logical pixels, as the app lays out.
final class RaccoonControl implements RaccoonControlCalls {
  RaccoonControl(this.host);

  final RaccoonControlHost host;

  /// Every method, in the order a tool list shows them.
  static const methods = [
    'list_devices',
    'run',
    'stop',
    'hot_reload',
    'hot_restart',
    'screenshot',
    'tap',
    'long_press',
    'drag',
    'scroll',
    'type_text',
    'press_key',
    'logs',
    'resize',
  ];

  @override
  Future<Map<String, Object?>> call(
    String method,
    Map<String, Object?> params,
  ) async {
    final clock = Stopwatch()..start();
    final result = await _call(method, _Params(params));
    return {...result, 'host': host.kind, 'ms': clock.elapsedMilliseconds};
  }

  Future<Map<String, Object?>> _call(String method, _Params params) async {
    switch (method) {
      case 'list_devices':
        return listDevices();
      case 'run':
        final project = params.string('project');
        final device = _deviceId(params.optionalString('device') ?? 'phone');
        final clock = Stopwatch()..start();
        host.announce(null, 'run $project on $device');
        final app = await host.run(
          project,
          device: device,
          target: params.optionalString('target'),
        );
        return {'app': describe(app), 'startup_ms': clock.elapsedMilliseconds};
      case 'stop':
        final app = target(params);
        host.announce(app, 'stop');
        await app.stop();
        return {'stopped': app.name};
      case 'hot_reload' || 'hot_restart':
        final app = target(params);
        if (!app.canReload) {
          throw RaccoonControlError(
            RaccoonControlError.unsupported,
            '${app.name} was not started here (started by ${app.startedBy}): '
            'reload it from where it was started',
          );
        }
        final full = method == 'hot_restart';
        host.announce(app, full ? 'hot restart' : 'hot reload');
        try {
          await (full ? app.hotRestart() : app.hotReload());
        } on RaccoonControlError {
          rethrow;
        } on Object catch (error) {
          throw RaccoonControlError(RaccoonControlError.failed, '$error');
        }
        return {'app': app.name};
      case 'screenshot':
        return screenshot(target(params), params);
      case 'tap':
        final app = target(params);
        final (x, y) = _point(params, app);
        host.announce(app, 'tap ${_n(x)}, ${_n(y)}');
        await _input(app).tap(x, y);
        return {'app': app.name};
      case 'long_press':
        final app = target(params);
        final (x, y) = _point(params, app);
        final hold = params.optionalNumber('hold_ms') ?? 650;
        host.announce(app, 'long press ${_n(x)}, ${_n(y)}');
        await _input(
          app,
        ).longPress(x, y, hold: Duration(milliseconds: hold.round()));
        return {'app': app.name};
      case 'drag':
        final app = target(params);
        final fromX = params.number('from_x');
        final fromY = params.number('from_y');
        final toX = params.number('to_x');
        final toY = params.number('to_y');
        final duration = params.optionalNumber('duration_ms') ?? 300;
        host.announce(
          app,
          'drag ${_n(fromX)}, ${_n(fromY)} to ${_n(toX)}, ${_n(toY)}',
        );
        await _input(app).drag(
          fromX,
          fromY,
          toX,
          toY,
          duration: Duration(milliseconds: duration.round()),
        );
        return {'app': app.name};
      case 'scroll':
        final app = target(params);
        final (x, y) = _point(params, app);
        final dx = params.optionalNumber('dx') ?? 0;
        final dy = params.optionalNumber('dy') ?? 0;
        host.announce(app, 'scroll ${_n(dx)}, ${_n(dy)} at ${_n(x)}, ${_n(y)}');
        await _input(app).scroll(x, y, dx: dx, dy: dy);
        return {'app': app.name};
      case 'type_text':
        final app = target(params);
        final text = params.string('text');
        host.announce(app, 'type ${jsonEncode(text)}');
        try {
          await _input(app).typeText(text);
        } on StateError catch (error) {
          throw RaccoonControlError(RaccoonControlError.failed, error.message);
        }
        return {'app': app.name};
      case 'press_key':
        final app = target(params);
        final RaccoonKey key;
        final List<RaccoonKey> modifiers;
        try {
          key = RaccoonKey.named(params.string('key'));
          modifiers = [
            for (final name in params.optionalStrings('modifiers'))
              RaccoonKey.named(name),
          ];
        } on ArgumentError catch (error) {
          throw RaccoonControlError(
            RaccoonControlError.badParams,
            '${error.message}: ${error.invalidValue}',
          );
        }
        final chord = [
          ...params.optionalStrings('modifiers'),
          params.string('key'),
        ].join('+');
        host.announce(app, 'press $chord');
        await _input(app).pressKey(key, modifiers: modifiers);
        return {'app': app.name};
      case 'logs':
        return logs(target(params), params);
      case 'resize':
        return resize(target(params), params);
      default:
        throw RaccoonControlError(
          RaccoonControlError.unknownMethod,
          'no method $method; there are ${methods.join(', ')}',
        );
    }
  }

  /// The devices, each with its size and the apps on it.
  Map<String, Object?> listDevices() {
    final apps = host.apps();
    final devices = host.devices();
    final listed = {for (final device in devices) device.id};
    return {
      'devices': [
        for (final device in devices)
          {
            'id': device.id,
            'label': device.label,
            'size': switch (device.size) {
              final size? => _size(size),
              null => null,
            },
            'apps': [
              for (final app in apps)
                if (RaccoonControlDevice.idOfApp(app.name) == device.id)
                  describe(app),
            ],
          },
        // Apps on devices the tool no longer lists, from before a change.
        for (final app in apps)
          if (!listed.contains(RaccoonControlDevice.idOfApp(app.name)))
            {
              'id': RaccoonControlDevice.idOfApp(app.name),
              'label': RaccoonControlDevice.idOfApp(app.name),
              'size': null,
              'apps': [describe(app)],
            },
      ],
    };
  }

  /// [app] as a call's result shows it.
  static Map<String, Object?> describe(RaccoonControlApp app) => {
    'name': app.name,
    'project': RunnerDiscovery.projectOf(app.name),
    'device': RaccoonControlDevice.idOfApp(app.name),
    'size': _size(app.size),
    'started_by': app.startedBy,
    'can_reload': app.canReload,
    'vm_service': app.vmServiceUri,
  };

  /// The app [params] point at: `device` and `app`, or the one app running.
  RaccoonControlApp target(Map<String, Object?> params) =>
      _target(_Params(params));

  RaccoonControlApp _target(_Params params) {
    final device = switch (params.optionalString('device')) {
      final device? => _deviceId(device),
      null => null,
    };
    final project = params.optionalString('app');
    final apps = host.apps();
    final matching = [
      for (final app in apps)
        if ((device == null ||
                RaccoonControlDevice.idOfApp(app.name) == device) &&
            (project == null ||
                RunnerDiscovery.projectOf(app.name) == project ||
                app.name == project))
          app,
    ];
    if (matching.length == 1) return matching.single;
    final where = [
      if (project != null) project,
      if (device != null) 'on $device',
    ].join(' ');
    if (matching.isEmpty) {
      final running = apps.map((app) => app.name).join(', ');
      throw RaccoonControlError(
        RaccoonControlError.noApp,
        'nothing runs${where.isEmpty ? '' : ' as $where'}; '
        '${running.isEmpty ? 'no app runs: call run first' : 'running: $running'}',
      );
    }
    throw RaccoonControlError(
      RaccoonControlError.ambiguous,
      'several apps run${where.isEmpty ? '' : ' $where'}: '
      '${matching.map((app) => app.name).join(', ')}; name the device and app',
    );
  }

  /// The settled frame as a PNG, base64, with its sizes.
  Future<Map<String, Object?>> screenshot(
    RaccoonControlApp app,
    Map<String, Object?> params,
  ) async {
    final p = _Params(params);
    final ratio = app.size.pixelRatio;
    final logical = p.optionalBool('logical') ?? false;
    final scale = p.optionalNumber('scale') ?? (logical ? 1 / ratio : 1.0);
    if (!(scale > 0) || scale > 1) {
      throw const RaccoonControlError(
        RaccoonControlError.badParams,
        'scale is above 0 and at most 1',
      );
    }
    host.announce(app, 'screenshot');
    final frame = await _settled(app);
    final png = await frame.png(scale: scale);
    return {
      'app': app.name,
      'png': base64Encode(png),
      'width': (frame.width * scale).round(),
      'height': (frame.height * scale).round(),
      'frame_width': frame.width,
      'frame_height': frame.height,
      'logical_width': frame.logicalWidth,
      'logical_height': frame.logicalHeight,
      'pixel_ratio': frame.pixelRatio,
      'scale': scale,
      'sequence': frame.frame.sequence.toInt(),
    };
  }

  Future<RaccoonFrame> _settled(RaccoonControlApp app) async {
    try {
      return await settledFrame(
        app.client,
        pixelRatio: app.size.pixelRatio,
        releaseGpuFrames: app.releasesGpuFrames,
        name: app.name,
      );
    } on TimeoutException catch (error) {
      throw RaccoonControlError(RaccoonControlError.failed, '$error');
    } on StateError catch (error) {
      throw RaccoonControlError(RaccoonControlError.failed, error.message);
    }
  }

  /// The run's log, filtered: `source` (`app`, `runner`, `tool`),
  /// `contains` (a substring) or `pattern` (a regular expression), the
  /// `last` lines (100 unless said).
  Map<String, Object?> logs(
    RaccoonControlApp app,
    Map<String, Object?> params,
  ) {
    final p = _Params(params);
    final source = switch (p.optionalString('source')) {
      null || 'all' => null,
      final name => DeviceLogSource.values.firstWhere(
        (source) => source.name == name,
        orElse:
            () =>
                throw RaccoonControlError(
                  RaccoonControlError.badParams,
                  'source is app, runner, tool or all, not $name',
                ),
      ),
    };
    final contains = p.optionalString('contains');
    final RegExp? pattern;
    try {
      pattern = switch (p.optionalString('pattern')) {
        final text? => RegExp(text),
        null => null,
      };
    } on FormatException catch (error) {
      throw RaccoonControlError(
        RaccoonControlError.badParams,
        'pattern: ${error.message}',
      );
    }
    final last = (p.optionalNumber('last') ?? 100).round();
    final all = app.logLines();
    final kept = [
      for (final line in all)
        if ((source == null || line.source == source) &&
            (contains == null || line.text.contains(contains)) &&
            (pattern == null || pattern.hasMatch(line.text)))
          line,
    ];
    final shown =
        last <= 0 || kept.length <= last
            ? kept
            : kept.sublist(kept.length - last);
    return {
      'app': app.name,
      'lines': [for (final line in shown) line.toJson()],
      'matched': kept.length,
      'total': all.length,
    };
  }

  /// Resizes the app as the board's handle does, and waits for its first
  /// frame at the new size.
  Future<Map<String, Object?>> resize(
    RaccoonControlApp app,
    Map<String, Object?> params,
  ) async {
    final p = _Params(params);
    final width = p.number('width');
    final height = p.number('height');
    final ratio = p.optionalNumber('pixel_ratio') ?? app.size.pixelRatio;
    if (width < 1 || height < 1 || !(ratio > 0) || ratio > 8) {
      throw const RaccoonControlError(
        RaccoonControlError.badParams,
        'width and height are at least 1, pixel_ratio above 0 and at most 8',
      );
    }
    final size = (width: width, height: height, pixelRatio: ratio);
    host.announce(app, 'resize to ${_n(width)} × ${_n(height)} @${_n(ratio)}x');
    final physicalWidth = (width * ratio).round();
    final physicalHeight = (height * ratio).round();
    final drawn = app.client.messages
        .where(
          (message) =>
              message.hasFrame() &&
              message.frame.width == physicalWidth &&
              message.frame.height == physicalHeight,
        )
        .first
        .timeout(const Duration(seconds: 10));
    drawn.ignore();
    await app.resize(size);
    final latest = app.client.latestFrame;
    if (latest == null ||
        latest.width != physicalWidth ||
        latest.height != physicalHeight) {
      try {
        await drawn;
      } on TimeoutException {
        throw RaccoonControlError(
          RaccoonControlError.failed,
          'no ${physicalWidth}x$physicalHeight frame from ${app.name} in 10 s',
        );
      }
    }
    return {'app': describe(app)};
  }

  RaccoonInput _input(RaccoonControlApp app) => RaccoonInput(
    app.client,
    pixelRatio: () => app.size.pixelRatio,
    name: app.name,
  );

  /// `x` and `y`, inside the app.
  (double, double) _point(_Params params, RaccoonControlApp app) {
    final x = params.number('x');
    final y = params.number('y');
    final size = app.size;
    if (x < 0 || y < 0 || x > size.width || y > size.height) {
      throw RaccoonControlError(
        RaccoonControlError.badParams,
        '($x, $y) is outside ${app.name}, which is '
        '${_n(size.width)} × ${_n(size.height)} logical pixels',
      );
    }
    return (x, y);
  }

  static String _deviceId(String device) => switch (device) {
    _ when RaccoonControlDevice.keyOf(device) != null => device,
    '1' => 'raccoon',
    _ => 'raccoon-$device',
  };

  static Map<String, Object?> _size(DeviceSize size) => {
    'width': size.width,
    'height': size.height,
    'pixel_ratio': size.pixelRatio,
  };

  static String _n(num value) =>
      value == value.roundToDouble()
          ? '${value.round()}'
          : value.toStringAsFixed(1);
}

/// A call's parameters, read with the error a caller can fix.
extension type _Params(Map<String, Object?> map)
    implements Map<String, Object?> {
  String string(String key) => switch (map[key]) {
    final String value when value.isNotEmpty => value,
    _ =>
      throw RaccoonControlError(
        RaccoonControlError.badParams,
        '$key is wanted, a string',
      ),
  };

  String? optionalString(String key) => switch (map[key]) {
    null => null,
    final String value when value.isNotEmpty => value,
    final String _ => null,
    _ =>
      throw RaccoonControlError(
        RaccoonControlError.badParams,
        '$key is a string',
      ),
  };

  double number(String key) => switch (map[key]) {
    final num value when value.isFinite => value.toDouble(),
    _ =>
      throw RaccoonControlError(
        RaccoonControlError.badParams,
        '$key is wanted, a number',
      ),
  };

  double? optionalNumber(String key) => switch (map[key]) {
    null => null,
    final num value when value.isFinite => value.toDouble(),
    _ =>
      throw RaccoonControlError(
        RaccoonControlError.badParams,
        '$key is a number',
      ),
  };

  bool? optionalBool(String key) => switch (map[key]) {
    null => null,
    final bool value => value,
    _ =>
      throw RaccoonControlError(
        RaccoonControlError.badParams,
        '$key is true or false',
      ),
  };

  List<String> optionalStrings(String key) => switch (map[key]) {
    null => const [],
    final List<Object?> values when values.every((v) => v is String) =>
      values.cast<String>(),
    _ =>
      throw RaccoonControlError(
        RaccoonControlError.badParams,
        '$key is a list of strings',
      ),
  };
}

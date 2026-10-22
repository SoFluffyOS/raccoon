/// A Raccoon device as the Flutter tool's picker lists it: an instance key
/// that keeps its runs apart (the helper's `--instance`, `<app>@key`), a
/// label, and for the sized ones the logical size and pixel ratio the
/// runner starts at and the hosts show it in.
final class RaccoonDevice {
  const RaccoonDevice({
    required this.key,
    required this.label,
    this.width,
    this.height,
    this.pixelRatio,
  });

  /// The pane's own size: the first device, `raccoon`.
  static const host = RaccoonDevice(key: '1', label: 'Raccoon');

  /// A second run of the same project, at whatever size the host picks;
  /// Lumide's previews run here.
  static const second = RaccoonDevice(key: '2', label: 'Raccoon 2');

  static const phone = RaccoonDevice(
    key: 'phone',
    label: 'Raccoon Phone',
    width: 390,
    height: 844,
    pixelRatio: 3,
  );
  static const tablet = RaccoonDevice(
    key: 'tablet',
    label: 'Raccoon Tablet',
    width: 820,
    height: 1180,
    pixelRatio: 2,
  );
  static const desktop = RaccoonDevice(
    key: 'desktop',
    label: 'Raccoon Desktop',
    width: 1280,
    height: 800,
    pixelRatio: 1,
  );

  /// The built-in devices, in the picker's order. Setup registers [host]
  /// alone; the rest, and any other name and size, are added when wanted.
  static const all = [host, second, phone, tablet, desktop];

  /// The sized presets a user adds by name: phone, tablet, desktop.
  static const presets = [phone, tablet, desktop];

  /// The device behind an instance key, null for one that is not built in.
  static RaccoonDevice? forKey(String key) {
    for (final device in all) {
      if (device.key == key) return device;
    }
    return null;
  }

  /// A device of the user's own: `raccoon-<key>`, labelled `Raccoon <key>`
  /// unless [label] says otherwise, at [size] (`1024x1366@2`) when given.
  /// The key is letters, digits, dots and dashes, as a device id allows.
  static RaccoonDevice custom(String key, {String? size, String? label}) {
    if (!_keyPattern.hasMatch(key)) {
      throw ArgumentError.value(key, 'key', 'letters, digits, . and - only');
    }
    final parsed = size == null ? null : parseSize(size);
    if (size != null && parsed == null) {
      throw ArgumentError.value(size, 'size', 'wanted WIDTHxHEIGHT@RATIO');
    }
    return RaccoonDevice(
      key: key,
      label: label ?? 'Raccoon ${key[0].toUpperCase()}${key.substring(1)}',
      width: parsed?.width,
      height: parsed?.height,
      pixelRatio: parsed?.pixelRatio,
    );
  }

  /// Reads `390x844@3`, or `390x844` at ratio 1; null for anything else.
  static ({int width, int height, double pixelRatio})? parseSize(String text) {
    final match = _sizePattern.firstMatch(text.trim());
    if (match == null) return null;
    final width = int.tryParse(match[1]!);
    final height = int.tryParse(match[2]!);
    final ratio = match[3] == null ? 1.0 : double.tryParse(match[3]!);
    if (width == null || height == null || ratio == null) return null;
    if (width <= 0 || height <= 0 || ratio <= 0) return null;
    return (width: width, height: height, pixelRatio: ratio);
  }

  static final _keyPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9.-]*$');
  static final _sizePattern = RegExp(r'^(\d+)x(\d+)(?:@(\d+(?:\.\d+)?))?$');

  /// The key part of an app name: `wonders@tablet` is on `tablet`,
  /// `wonders` on `1`.
  final String key;
  final String label;
  final int? width;
  final int? height;
  final double? pixelRatio;

  /// The Flutter tool's device id: `raccoon`, `raccoon-tablet`.
  String get id => key == '1' ? 'raccoon' : 'raccoon-$key';

  bool get hasSize => width != null && height != null;

  /// What the helper takes as `--size`: `390x844@3`; null without a size.
  String? get sizeArgument {
    final width = this.width;
    final height = this.height;
    if (width == null || height == null) return null;
    final ratio = pixelRatio ?? 1;
    final ratioText =
        ratio == ratio.roundToDouble() ? '${ratio.round()}' : '$ratio';
    return '${width}x$height@$ratioText';
  }

  @override
  String toString() => '$label ($id)';
}

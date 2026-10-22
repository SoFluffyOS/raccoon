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

  /// Every device the helper registers, in the picker's order.
  static const all = [host, second, phone, tablet, desktop];

  /// The device behind an instance key, null for one that is not built in.
  static RaccoonDevice? forKey(String key) {
    for (final device in all) {
      if (device.key == key) return device;
    }
    return null;
  }

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
    final ratioText = ratio == ratio.roundToDouble()
        ? '${ratio.round()}'
        : '$ratio';
    return '${width}x$height@$ratioText';
  }

  @override
  String toString() => '$label ($id)';
}

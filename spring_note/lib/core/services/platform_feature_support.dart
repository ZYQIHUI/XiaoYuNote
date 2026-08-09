import 'dart:io';

class PlatformFeatureSupport {
  const PlatformFeatureSupport._();

  static bool get supportsAutoStart =>
      Platform.isWindows || (Platform.isMacOS && _isMacOS13OrNewer());

  static bool get supportsGlobalHotkeys => Platform.isWindows || Platform.isMacOS;

  static bool get supportsTray => Platform.isWindows || Platform.isMacOS;

  static bool get supportsDesktopWidget => Platform.isWindows || Platform.isMacOS;

  static bool _isMacOS13OrNewer() {
    final match = RegExp(
      r'(?:Version\s+)?(\d+)(?:\.\d+)?',
    ).firstMatch(Platform.operatingSystemVersion);
    final majorVersion = int.tryParse(match?.group(1) ?? '');
    return majorVersion != null && majorVersion >= 13;
  }
}

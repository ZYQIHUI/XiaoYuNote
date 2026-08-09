import 'dart:ui' show PlatformDispatcher;

/// 把配置的语言偏好（'system' / 'zh' / 'en'）解析为实际生效的语言代码。
///
/// 供没有 BuildContext 的场景使用（配置默认值、AI 提示词选择等）；
/// UI 层应优先使用当前 Localizations 的语言。
String resolveAppLanguage(String configured) {
  if (configured == 'zh' || configured == 'en') {
    return configured;
  }
  final locale = PlatformDispatcher.instance.locale;
  return locale.languageCode.toLowerCase().startsWith('zh') ? 'zh' : 'en';
}

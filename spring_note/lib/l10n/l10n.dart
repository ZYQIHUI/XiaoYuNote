import 'package:flutter/widgets.dart';

import 'app_localizations.dart';
import 'app_localizations_zh.dart';

/// 获取当前语言的文案。
///
/// 在未挂载 [AppLocalizations] 的环境（例如未配置 localizationsDelegates 的
/// widget 测试）中回退到中文，避免测试必须逐个声明 delegates。
AppLocalizations l10n(BuildContext context) {
  return Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      AppLocalizationsZh();
}

/// 当前界面语言（'zh' 或 'en'），供需要与界面语言一致的内容使用（如默认提示词）。
String currentAppLanguage(BuildContext context) {
  return l10n(context).localeName.toLowerCase().startsWith('en') ? 'en' : 'zh';
}

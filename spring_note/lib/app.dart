import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/cupertino.dart' show CupertinoLocalizations;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/models/app_config.dart';
import 'core/models/local_data_state.dart';
import 'core/router/app_shell.dart';
import 'core/services/kb_rust_client.dart';
import 'core/services/local_data_service.dart';
import 'core/services/note_service.dart';
import 'core/services/stats_service.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/app_window_frame.dart';
import 'features/sheets/sheet_editor_page.dart' show univerServerBaseUrl;
import 'l10n/app_localizations.dart';
import 'l10n/l10n.dart';
import 'src/rust/api/kb_api.dart' as kb_api;

class XiaoYuNoteApp extends StatefulWidget {
  const XiaoYuNoteApp({
    super.key,
    this.localDataService = const LocalDataService(),
    this.statsService = const StatsService(),
    this.noteService = const NoteService(),
  });

  final LocalDataService localDataService;
  final StatsService statsService;
  final NoteService noteService;

  @override
  State<XiaoYuNoteApp> createState() => _XiaoYuNoteAppState();
}

class _XiaoYuNoteAppState extends State<XiaoYuNoteApp> {
  AppConfig _config = AppConfig.defaults();
  late final Future<LocalDataState> _initFuture = _initialize();
  AppLifecycleListener? _lifecycleListener;

  @override
  void initState() {
    super.initState();
    // 应用退出时直接退出（sidecar 已移除）
    _lifecycleListener = AppLifecycleListener(
      onExitRequested: () async {
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycleListener?.dispose();
    super.dispose();
  }

  Future<LocalDataState> _initialize() async {
    final state = await widget.localDataService.initialize();
    await widget.statsService.recordAppStartup(appDataDir: state.dataDirectory);
    // 设置 Rust 知识库数据目录（替代原 sidecar 启动）
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      KbRustClient.defaultDataDir = state.dataDirectory;
      // 预启动 Univer 静态服务器（ES module 需 http://，file:// 会被 CORS 拦截）
      try {
        final base = await kb_api.kbStartUniverServer();
        if (base.isNotEmpty) {
          univerServerBaseUrl = base;
        }
      } catch (_) {
        // 服务器启动失败不影响主流程，表格页会回退 file://
      }
    }
    if (mounted) {
      setState(() => _config = state.config);
    } else {
      _config = state.config;
    }
    return state;
  }

  void _handleConfigChanged(AppConfig config) {
    if (mounted) {
      setState(() => _config = config);
    }
  }

  Locale? _resolveLocale(String language) {
    return switch (language) {
      'zh' => const Locale.fromSubtags(languageCode: 'zh', countryCode: 'CN'),
      'en' => const Locale('en'),
      _ => null,
    };
  }

  bool _englishUi(BuildContext context) {
    final explicit = _resolveLocale(_config.language);
    if (explicit != null) {
      return explicit.languageCode.startsWith('en');
    }
    return Localizations.localeOf(context).languageCode.startsWith('en');
  }

  @override
  Widget build(BuildContext context) {
    final fontScale = AppTheme.fontScaleFactor(_config.fontScale);
    return MaterialApp(
      title: 'XiaoYuNote',
      debugShowCheckedModeBanner: false,
      locale: _resolveLocale(_config.language),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // 必须是 zh_CN 而不是裸 zh：引擎按 Locale 选择中文回退字体，
      // 裸 zh 会丢掉简体中文偏好，回退到更细的字体（如微软正黑体）。
      supportedLocales: const [
        Locale.fromSubtags(languageCode: 'zh', countryCode: 'CN'),
        Locale('en'),
      ],
      theme: AppTheme.light(appFont: _config.appFont),
      darkTheme: AppTheme.dark(appFont: _config.appFont),
      themeMode: _themeMode(_config.themeMode),
      themeAnimationDuration: Duration.zero,
      themeAnimationCurve: Curves.linear,
      builder: (context, child) {
        final mediaQuery = MediaQuery.of(context);
        Widget content = MediaQuery(
          data: mediaQuery.copyWith(textScaler: TextScaler.linear(fontScale)),
          child: child ?? const SizedBox.shrink(),
        );
        // 英文界面下：文本整形/字体回退仍按 zh_CN（与中文界面一致），
        // 文案资源强制加载英文。引擎与 RichText 都按 Localizations
        // 的 locale 选择中文回退字体，包这层后中文内容在英文界面下
        // 不会落到更细的英文回退字体上。
        if (_englishUi(context)) {
          content = Localizations.override(
            context: context,
            locale: const Locale.fromSubtags(
              languageCode: 'zh',
              countryCode: 'CN',
            ),
            delegates: const [
              _ForceEnglishDelegate<AppLocalizations>(AppLocalizations.delegate),
              _ForceEnglishDelegate<MaterialLocalizations>(
                GlobalMaterialLocalizations.delegate,
              ),
              _ForceEnglishDelegate<WidgetsLocalizations>(
                GlobalWidgetsLocalizations.delegate,
              ),
              _ForceEnglishDelegate<CupertinoLocalizations>(
                GlobalCupertinoLocalizations.delegate,
              ),
            ],
            child: content,
          );
        }
        return content;
      },
      home: AppWindowFrame(
        child: FutureBuilder<LocalDataState>(
          future: _initFuture,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return AppStartupError(error: snapshot.error.toString());
            }

            if (!snapshot.hasData) {
              return const AppStartupLoading();
            }

            return AppShell(
              localDataState: snapshot.data!,
              noteService: widget.noteService,
              onConfigChanged: _handleConfigChanged,
            );
          },
        ),
      ),
    );
  }

  ThemeMode _themeMode(AppThemePreference preference) {
    return switch (preference) {
      AppThemePreference.system => ThemeMode.system,
      AppThemePreference.light => ThemeMode.light,
      AppThemePreference.dark => ThemeMode.dark,
    };
  }
}

class AppStartupLoading extends StatelessWidget {
  const AppStartupLoading({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: SizedBox.expand());
  }
}

class AppStartupError extends StatelessWidget {
  const AppStartupError({super.key, required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colors(context);
    return Scaffold(
      body: Center(
        child: Container(
          width: 520,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border.all(color: colors.border),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n(context).coreStartupFailedTitle,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Text(
                error,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: colors.textSubtle),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 始终加载英文资源的委托：配合 `Localizations.override(locale: zh_CN)`
/// 使用，让英文界面下的文本整形/字体回退仍走 zh_CN，而界面文案保持英文。
class _ForceEnglishDelegate<T> extends LocalizationsDelegate<T> {
  const _ForceEnglishDelegate(this.delegate);

  final LocalizationsDelegate<T> delegate;

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<T> load(Locale locale) => delegate.load(const Locale('en'));

  @override
  bool shouldReload(_ForceEnglishDelegate<T> old) => false;
}

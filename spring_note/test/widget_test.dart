import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spring_note/app.dart';
import 'package:spring_note/core/models/app_config.dart';
import 'package:spring_note/core/models/local_data_state.dart';
import 'package:spring_note/core/router/app_shell.dart';
import 'package:spring_note/core/services/local_data_service.dart';
import 'package:spring_note/core/services/stats_service.dart';
import 'package:spring_note/core/theme/app_theme.dart';

void main() {
  testWidgets(
    'XiaoYuNote app disables theme transition to avoid input flicker',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        XiaoYuNoteApp(
          localDataService: _ImmediateLocalDataService(_testLocalDataState()),
          statsService: const _NoopStartupStatsService(),
        ),
      );

      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.themeAnimationDuration, Duration.zero);
      expect(app.themeAnimationCurve, Curves.linear);
    },
  );

  testWidgets('app shell shows three-section sidebar', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = _testLocalDataState();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: AppShell(localDataState: state),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // 三个导航项：便签（默认选中）、知识库、设置
    expect(find.byTooltip('便签'), findsOneWidget);
    expect(find.byTooltip('知识库'), findsOneWidget);
    expect(find.byTooltip('设置'), findsOneWidget);
  });

  testWidgets('app shell switches to settings section', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = _testLocalDataState();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: AppShell(localDataState: state),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byTooltip('设置'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('偏好设置'), findsWidgets);
  });}

class _ImmediateLocalDataService extends LocalDataService {
  _ImmediateLocalDataService(this.state);

  final LocalDataState state;

  @override
  Future<LocalDataState> initialize() async => state;

  @override
  Future<AppConfig> readConfig() async => state.config;

  @override
  Future<void> saveConfig(AppConfig config) async {}
}

class _NoopStartupStatsService extends StatsService {
  const _NoopStartupStatsService();

  @override
  Future<void> recordAppStartup({required String appDataDir}) async {}
}

LocalDataState _testLocalDataState({AppConfig? config}) {
  final directory = Directory.systemTemp.createTempSync('xyn_widget_test_');
  addTearDown(() {
    try {
      directory.deleteSync(recursive: true);
    } catch (_) {}
  });
  return LocalDataState(
    dataDirectory: directory.path,
    configPath: '${directory.path}${Platform.pathSeparator}config.json',
    dailyNotesDirectory: '${directory.path}${Platform.pathSeparator}notes'
        '${Platform.pathSeparator}daily',
    weeklyNotesDirectory: '${directory.path}${Platform.pathSeparator}notes'
        '${Platform.pathSeparator}weekly',
    monthlyNotesDirectory: '${directory.path}${Platform.pathSeparator}notes'
        '${Platform.pathSeparator}monthly',
    config: (config ?? AppConfig.defaults()).copyWith(language: 'zh'),
  );
}

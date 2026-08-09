/// HomePage 知识库状态卡片测试 — 注入 FakeKbDataSource，
/// 验证状态文案、未连接态与索引/跳转回调。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spring_note/core/models/app_config.dart';
import 'package:spring_note/core/models/local_data_state.dart';
import 'package:spring_note/core/services/sidecar_client.dart';
import 'package:spring_note/features/home/home_page.dart';
import 'package:spring_note/features/kb/kb_page.dart';

class FakeKbDataSource implements KbDataSource {
  FakeKbDataSource({this.failHealth = false, this.indexCalls = 0});

  final bool failHealth;
  int indexCalls;

  @override
  Future<Map<String, dynamic>> health() async {
    if (failHealth) throw const SidecarUnavailableException('未找到 sidecar 配置');
    return {'status': 'ok', 'llm_ready': true, 'index': {}};
  }

  @override
  Future<Map<String, dynamic>> stats() async =>
      {'files': 12, 'chunks': 34, 'cells': 56, 'embedding_model': null};

  @override
  Future<Map<String, dynamic>> filesTree() async => {'name': 'd', 'type': 'dir', 'children': []};

  @override
  Future<Map<String, dynamic>> index() async {
    indexCalls++;
    return {'ok': 1};
  }

  @override
  Future<String> readText(String path) async => '';

  @override
  Stream<SidecarAskEvent> askStream(String query, {int? k, String? path}) async* {}
}

void main() {
  testWidgets('知识库卡片显示索引状态并支持一键索引与跳转', (tester) async {
    final ds = FakeKbDataSource();
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePage(
            localDataState: _testLocalDataState(),
            kbDataSource: ds,
            onOpenKb: () => opened = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 滚动到知识库卡片（首页 ListView 懒加载，卡片在视口下方）
    await tester.scrollUntilVisible(find.text('知识库'), 300, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();

    // 状态文案：文件 12 · 块 34 · 单元格 56 · LLM 就绪
    expect(find.text('知识库'), findsOneWidget);
    expect(find.textContaining('文件 12'), findsOneWidget);
    expect(find.textContaining('块 34'), findsOneWidget);
    expect(find.textContaining('单元格 56'), findsOneWidget);
    expect(find.textContaining('LLM 就绪'), findsOneWidget);

    // 一键索引
    await tester.tap(find.byTooltip('立即索引'));
    await tester.pumpAndSettle();
    expect(ds.indexCalls, 1);

    // 跳转回调
    await tester.tap(find.byTooltip('打开知识库面板'));
    await tester.pump();
    expect(opened, isTrue);
  });

  testWidgets('sidecar 未连接时卡片显示提示', (tester) async {
    final ds = FakeKbDataSource(failHealth: true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: HomePage(localDataState: _testLocalDataState(), kbDataSource: ds)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.textContaining('sidecar 未连接'), 300, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('sidecar 未连接'), findsOneWidget);
  });
}

LocalDataState _testLocalDataState() {
  return LocalDataState(
    dataDirectory: '.',
    configPath: './config.json',
    dailyNotesDirectory: './daily',
    weeklyNotesDirectory: './weekly',
    monthlyNotesDirectory: './monthly',
    config: AppConfig.defaults(),
  );
}

library;

/// KbPage widget 测试 — 注入内存 FakeKbDataSource（无网络），
/// 验证文件树渲染、状态栏、SSE 流式问答与引用展示。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spring_note/core/services/sidecar_client.dart';
import 'package:spring_note/features/kb/kb_page.dart';

class FakeKbDataSource implements KbDataSource {
  FakeKbDataSource({this.throwOnInit = false});

  final bool throwOnInit;
  final List<String> requests = [];

  @override
  Future<Map<String, dynamic>> health() async {
    requests.add('health');
    if (throwOnInit) throw const SidecarUnavailableException('未找到 sidecar 配置');
    return {'status': 'ok', 'llm_ready': false, 'index': {'files': 2, 'chunks': 3}};
  }

  @override
  Future<Map<String, dynamic>> stats() async {
    requests.add('stats');
    return {'files': 2, 'chunks': 3, 'cells': 12, 'embedding_model': null};
  }

  @override
  Future<Map<String, dynamic>> filesTree() async {
    requests.add('tree');
    return {
      'name': 'data',
      'type': 'dir',
      'children': [
        {
          'name': '个人',
          'type': 'dir',
          'children': [
            {'name': '对账清单.xlsx', 'type': 'file', 'size': 10},
            {'name': '日报.md', 'type': 'file', 'size': 10},
          ],
        },
        {'name': 'notes', 'type': 'dir', 'children': []},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> index() async {
    requests.add('index');
    return {'ok': 1};
  }

  @override
  Future<Map<String, dynamic>> config() async {
    requests.add('config');
    return {
      'sources': ['个人', 'notes'],
      'extra_sources': ['D:/外部资料'],
    };
  }

  @override
  Future<String> readText(String path) async => '# 日报\n- 拼房对账完成';

  @override
  Stream<SidecarAskEvent> askStream(String query, {int? k, String? path}) async* {
    requests.add('ask:$query');
    yield const SidecarAskEvent('retrieved', {
      'chunks': [{'source': '个人/对账清单.xlsx', 'score': 0.9}],
    });
    yield const SidecarAskEvent('answer', {'text': '命中单号'});
    yield const SidecarAskEvent('answer', {'text': 'D20260721002'});
    yield const SidecarAskEvent('done', {
      'refs': [{'source': '个人/对账清单.xlsx'}],
    });
  }
}

void main() {
  testWidgets('KbPage 渲染知识库范围、状态栏并完成流式问答', (tester) async {
    final ds = FakeKbDataSource();
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: KbPage(dataSource: ds))),
    );
    await tester.pumpAndSettle();

    // 左侧知识库范围（文件夹路径列表，非文件树）
    expect(find.text('知识库范围'), findsOneWidget);
    expect(find.text('个人'), findsOneWidget);
    expect(find.text('notes'), findsOneWidget);
    expect(find.text('外部文件夹'), findsOneWidget);
    expect(find.text('D:/外部资料'), findsOneWidget);

    // 状态栏（索引统计 + 立即索引按钮）
    expect(find.text('文件 2'), findsOneWidget);
    expect(find.text('立即索引'), findsOneWidget);

    // 问答：输入 → SSE 流式渲染
    await tester.enterText(find.byType(TextField), '对账清单单号');
    await tester.tap(find.text('问'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('命中单号'), findsOneWidget);
    expect(find.textContaining('D20260721002'), findsOneWidget);
    // 引用 chip
    expect(find.textContaining('对账清单.xlsx'), findsWidgets);
    expect(ds.requests, contains('ask:对账清单单号'));

    // 立即索引
    await tester.tap(find.text('立即索引'));
    await tester.pumpAndSettle();
    expect(ds.requests, contains('index'));
  });

  testWidgets('数据源初始化失败时显示重试', (tester) async {
    final ds = FakeKbDataSource(throwOnInit: true);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: KbPage(dataSource: ds))),
    );
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
  });
}

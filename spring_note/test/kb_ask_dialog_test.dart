/// 边写边问 KbAskDialog 测试 — 注入 FakeKbDataSource（无网络），
/// 验证 SSE 流式渲染、引用展示与「插入到编辑器」。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spring_note/core/services/sidecar_client.dart';
import 'package:spring_note/features/kb/kb_page.dart';
import 'package:spring_note/features/notes/notes_page.dart';

class FakeKbDataSource implements KbDataSource {
  FakeKbDataSource({this.fail = false});

  final bool fail;

  @override
  Future<Map<String, dynamic>> health() async => {'status': 'ok'};
  @override
  Future<Map<String, dynamic>> stats() async => {};
  @override
  Future<Map<String, dynamic>> filesTree() async => {'name': 'd', 'type': 'dir', 'children': []};
  @override
  Future<Map<String, dynamic>> index() async => {};
  @override
  Future<Map<String, dynamic>> config() async => {'sources': [], 'extra_sources': []};
  @override
  Future<String> readText(String path) async => '';

  @override
  Stream<SidecarAskEvent> askStream(String query, {int? k, String? path}) async* {
    if (fail) {
      yield const SidecarAskEvent('error', {'message': 'AI 未配置'});
      return;
    }
    yield const SidecarAskEvent('answer', {'text': '答案是'});
    yield const SidecarAskEvent('answer', {'text': 'D20260721002 已对账'});
    yield const SidecarAskEvent('done', {
      'refs': [{'source': '个人/对账清单.xlsx'}],
    });
  }
}

void main() {
  testWidgets('KbAskDialog 流式渲染回答、显示引用并可插入编辑器', (tester) async {
    final controller = TextEditingController(text: '原有内容');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KbAskDialog(
            question: '单号多少',
            controller: controller,
            dataSource: FakeKbDataSource(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // 流式回答累积
    expect(find.textContaining('答案是'), findsOneWidget);
    expect(find.textContaining('D20260721002 已对账'), findsOneWidget);

    // 引用 chip
    expect(find.text('个人/对账清单.xlsx'), findsOneWidget);

    // 插入到编辑器
    await tester.tap(find.text('插入到编辑器'));
    await tester.pump();
    expect(find.text('已插入'), findsOneWidget);
    expect(controller.text, contains('原有内容'));
    expect(controller.text, contains('D20260721002 已对账'));
    expect(controller.text, contains('\n\n'));

    // 清理 widget 树（避免 leak_tracker 报告）
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('检索失败显示错误信息', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KbAskDialog(
            question: 'x',
            controller: controller,
            dataSource: FakeKbDataSource(fail: true),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('AI 未配置'), findsOneWidget);
    expect(find.text('插入到编辑器'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}

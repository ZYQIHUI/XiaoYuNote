library;

/// SidecarClient 单元测试 — 用 dart:io HttpServer mock 侧车，
/// 验证 token 头、SSE 事件流解析、错误处理与连接加载。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spring_note/core/services/sidecar_client.dart';

void main() {
  group('SidecarClient', () {
    test('loadConnection 从 .sidecar.json 读取 token 与端口', () async {
      final dir = Directory.systemTemp.createTempSync('sidecar_cfg_');
      File('${dir.path}${Platform.pathSeparator}.sidecar.json')
          .writeAsStringSync(jsonEncode({'token': 'tok-abc', 'port': 9999}));

      final client = SidecarClient(dataDir: dir.path);
      await client.loadConnection();
      expect(client.isConfigured, isTrue);

      dir.deleteSync(recursive: true);
    });

    test('缺少 .sidecar.json 时抛 SidecarUnavailableException', () async {
      final client = SidecarClient(dataDir: '/nonexistent/path');
      expect(client.loadConnection(), throwsA(isA<SidecarUnavailableException>()));
    });

    test('请求携带 X-Token 且 health 返回解析结果', () async {
      String? seenToken;
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) {
        seenToken = req.headers.value('X-Token');
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'status': 'ok', 'llm_ready': false}))
          ..close();
      });

      final client = SidecarClient(port: server.port, token: 'secret-token');
      final r = await client.health();
      expect(seenToken, 'secret-token');
      expect(r['status'], 'ok');
      await server.close(force: true);
    });

    test('401 响应抛 SidecarUnavailableException', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) {
        req.response
          ..statusCode = 401
          ..headers.contentType = ContentType.json
          ..write('{"detail":"invalid token"}')
          ..close();
      });

      final client = SidecarClient(port: server.port, token: 'wrong');
      await expectLater(
        client.stats(),
        throwsA(isA<SidecarUnavailableException>()),
      );
      await server.close(force: true);
    });

    test('askStream 解析 SSE 事件序列', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8')
          ..write('event: status\ndata: {"phase":"retrieving"}\n\n')
          ..write('event: retrieved\ndata: {"chunks":[{"source":"a.md","score":0.9}]}\n\n')
          ..write('event: answer\ndata: {"text":"第一段"}\n\n')
          ..write('event: answer\ndata: {"text":"第二段"}\n\n')
          ..write('event: done\ndata: {"refs":[{"source":"a.md"}]}\n\n')
          ..close();
      });

      final client = SidecarClient(port: server.port, token: 't');
      final events = await client.askStream('测试问题').toList();
      expect(events.map((e) => e.type), ['status', 'retrieved', 'answer', 'answer', 'done']);
      expect(events[2].data['text'], '第一段');
      expect(events[3].data['text'], '第二段');
      expect((events[4].data['refs'] as List).length, 1);
      await server.close(force: true);
    });

    test('askStream 透传 error 事件', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8')
          ..write('event: error\ndata: {"message":"AI 未配置"}\n\n')
          ..close();
      });

      final client = SidecarClient(port: server.port, token: 't');
      final events = await client.askStream('q').toList();
      expect(events.single.type, 'error');
      expect(events.single.data['message'], 'AI 未配置');
      await server.close(force: true);
    });

    test('sheets 解析 hits 列表', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) {
        expect(req.uri.queryParameters['q'], 'D20260721002');
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'query': 'D20260721002',
            'hits': [
              {'rel_path': '个人/a.xlsx', 'sheet_name': '对账', 'row': 2, 'col': 1, 'col_letter': 'A', 'header': '单号', 'value': 'D20260721002', 'ref': '个人/a.xlsx!对账 A2'},
            ],
            'count': 1,
          }))
          ..close();
      });

      final client = SidecarClient(port: server.port, token: 't');
      final hits = await client.sheets('D20260721002');
      expect(hits.length, 1);
      expect(hits.first['ref'], '个人/a.xlsx!对账 A2');
      await server.close(force: true);
    });

    test('readXlsx 返回 base64 内容', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) {
        expect(req.uri.path, '/api/files/xlsx');
        expect(req.uri.queryParameters['path'], '个人/对账清单.xlsx');
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'path': '个人/对账清单.xlsx', 'content_base64': 'AAAA', 'size': 3}))
          ..close();
      });

      final client = SidecarClient(port: server.port, token: 't');
      final r = await client.readXlsx('个人/对账清单.xlsx');
      expect(r['content_base64'], 'AAAA');
      await server.close(force: true);
    });

    test('writeXlsx PUT base64 内容', () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) async {
        expect(req.method, 'POST');
        expect(req.uri.path, '/api/files/xlsx');
        final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
        expect(body['path'], '个人/对账清单.xlsx');
        expect(body['content_base64'], 'QUJD');
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'ok': true}))
          ..close();
      });

      final client = SidecarClient(port: server.port, token: 't');
      final r = await client.writeXlsx('个人/对账清单.xlsx', 'QUJD');
      expect(r['ok'], true);
      await server.close(force: true);
    });
  });
}

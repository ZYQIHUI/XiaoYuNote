library;

/// SidecarLifecycle 测试 — 已有实例复用、目录解析、stop 幂等。
/// （spawn 真实进程路径不在此测试，避免依赖本机 Python/服务）

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spring_note/core/services/sidecar_client.dart';
import 'package:spring_note/core/services/sidecar_lifecycle.dart';

void main() {
  test('sidecar 已在运行（health 可达）时复用，不启动新进程', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) {
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write('{"status":"ok"}')
        ..close();
    });

    final lifecycle = SidecarLifecycle.forTest();
    lifecycle.clientFactory = () => SidecarClient(port: server.port, token: 't');

    await lifecycle.start();
    expect(lifecycle.isManaged, isFalse, reason: 'health 可达时应复用现有实例');

    await lifecycle.stop(); // 幂等：无托管进程时安全
    await server.close(force: true);
  });

  test('sidecar 不可达且无 sidecar 目录时降级不崩溃', () async {
    final lifecycle = SidecarLifecycle.forTest();
    lifecycle.clientFactory = () => SidecarClient(port: 1, token: 't'); // 必然失败
    // 指向不存在的 sidecar 目录，spawn 会抛异常 → start() 捕获降级
    lifecycle.resolveDirOverride = () => throw const SidecarUnavailableException('无目录');

    await lifecycle.start();
    expect(lifecycle.isManaged, isFalse);
  });

  test('目录解析优先使用 SIDECAR_DIR 环境变量', () {
    final dir = Directory.systemTemp.createTempSync('sidecar_dir_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final lifecycle = SidecarLifecycle.forTest();
    lifecycle.envOverride = {'SIDECAR_DIR': dir.path};
    expect(lifecycle.resolveSidecarDirForTest(), dir.path);
  });

  test('stop 无托管进程时安全', () async {
    final lifecycle = SidecarLifecycle.forTest();
    await lifecycle.stop();
    await lifecycle.stop(); // 幂等
  });
}

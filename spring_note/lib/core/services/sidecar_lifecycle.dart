/// 侧车生命周期管理 — 应用启动时 spawn sidecar、health 等待就绪，
/// 已运行实例则复用；应用退出时清理自己启动的进程。
///
/// 开发期：在仓库 sidecar/ 目录 `python -m sidecar`；
/// 打包后：随应用分发的 sidecar 可执行（M4 打包）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:spring_note/core/services/sidecar_client.dart';

class SidecarLifecycle {
  SidecarLifecycle._();

  static final SidecarLifecycle instance = SidecarLifecycle._();

  /// 测试用独立实例（隔离状态）。
  @visibleForTesting
  factory SidecarLifecycle.forTest() => SidecarLifecycle._();

  /// 可注入的客户端工厂（测试用）；默认按数据目录加载连接。
  @visibleForTesting
  SidecarClient Function() clientFactory = SidecarClient.new;

  /// 可注入的 sidecar 目录解析（测试用）。
  @visibleForTesting
  String Function()? resolveDirOverride;

  /// 可注入的环境变量表（测试用）；默认读取 Platform.environment。
  @visibleForTesting
  Map<String, String>? envOverride;

  /// Flutter 数据目录（笔记目录）；sidecar 知识库位置的默认跟随目标。
  /// 由 app 在数据目录加载完成后设置（spawn 前）。
  String? dataDirectory;

  /// 知识库（sidecar）数据目录；null = 跟随 [dataDirectory]。
  /// 注入为环境变量 XIAOYU_DATA_DIR，决定 kb.sqlite3 与业务文件区位置。
  String? kbDataDir;

  Process? _process;
  bool _started = false;
  bool _stopping = false;

  bool get isManaged => _process != null;

  /// 应用启动时调用（fire-and-forget，不阻塞 UI；失败仅降级）。
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      _process = await _spawnIfNeeded();
      if (_process != null) {
        // 消费子进程输出，避免管道阻塞
        _process!.stdout.listen((_) {});
        _process!.stderr.listen((_) {});
        debugPrint('sidecar 已启动（pid=${_process!.pid}）');
      }
    } catch (e) {
      debugPrint('sidecar 启动失败（降级运行）：$e');
    }
  }

  /// 若已有 sidecar 实例（health 可达）则复用；否则启动新进程。
  Future<Process?> _spawnIfNeeded() async {
    final client = clientFactory();
    if (!client.isConfigured) {
      try {
        await client.loadConnection();
      } catch (_) {
        // 无配置也继续尝试（可能为 spawn 场景）
      }
    }
    try {
      await client.health().timeout(const Duration(seconds: 2));
      debugPrint('sidecar 已在运行，复用现有实例');
      return null;
    } catch (_) {
      // 无实例，继续启动
    }

    final sidecarDir =
        resolveDirOverride != null ? resolveDirOverride!() : _resolveSidecarDir();
    final env = Map<String, String>.from(Platform.environment);
    // 知识库位置：kbDataDir > dataDirectory；缺失时不注入（sidecar 用默认 %APPDATA%\XiaoYu）
    final kbDir = kbDataDir ?? dataDirectory;
    if (kbDir != null && kbDir.isNotEmpty) {
      env['XIAOYU_DATA_DIR'] = kbDir;
    }
    // 同步给 Flutter 客户端，使读取的 .sidecar.json 与 sidecar 写入的一致（避免 401）
    SidecarClient.configuredDataDir = kbDir;
    // 优先使用打包后的可执行（PyInstaller onedir），其次 Python 源码
    final exe = _resolveSidecarExecutable(sidecarDir);
    if (exe != null) {
      debugPrint('sidecar 使用打包可执行：$exe');
      return Process.start(
        exe,
        const [],
        workingDirectory: File(exe).parent.path,
        environment: env,
        mode: ProcessStartMode.detachedWithStdio,
      );
    }
    final python = await _findPython();
    return Process.start(
      python,
      ['-m', 'sidecar'],
      workingDirectory: sidecarDir,
      environment: env,
      mode: ProcessStartMode.detachedWithStdio,
    );
  }

  /// sidecar 目录解析（测试入口）：环境变量 > 打包后 exe 同目录 > 开发仓库路径。
  @visibleForTesting
  String resolveSidecarDirForTest() => _resolveSidecarDir();

  String _resolveSidecarDir() {
    final env = envOverride ?? Platform.environment;
    final envDir = env['SIDECAR_DIR'];
    if (envDir != null && envDir.isNotEmpty && Directory(envDir).existsSync()) {
      return envDir;
    }
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final bundled = '$exeDir${Platform.pathSeparator}sidecar';
    if (Directory(bundled).existsSync()) {
      return bundled;
    }
    // 开发期：spring_note/../sidecar
    final dev = Directory.current.parent.path;
    if (Directory('$dev${Platform.pathSeparator}sidecar').existsSync()) {
      return '$dev${Platform.pathSeparator}sidecar';
    }
    throw const SidecarUnavailableException('未找到 sidecar 目录（可设置 SIDECAR_DIR）');
  }

  /// 在 sidecar 目录中查找打包可执行（PyInstaller onedir）。
  /// 支持两种布局：sidecar/xiaoyu-sidecar.exe 或 sidecar/xiaoyu-sidecar/xiaoyu-sidecar.exe。
  String? _resolveSidecarExecutable(String dir) {
    final base = Directory(dir);
    if (!base.existsSync()) {
      return null;
    }
    for (final candidate in [
      '${base.path}${Platform.pathSeparator}xiaoyu-sidecar.exe',
      '${base.path}${Platform.pathSeparator}xiaoyu-sidecar'
          '${Platform.pathSeparator}xiaoyu-sidecar.exe',
    ]) {
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }
    return null;
  }

  Future<String> _findPython() async {
    for (final cmd in ['python', 'py', 'python3']) {
      try {
        final r = await Process.run(cmd, ['--version']);
        if (r.exitCode == 0) return cmd;
      } catch (_) {
        // 继续尝试下一个
      }
    }
    throw const SidecarUnavailableException('未找到 Python（sidecar 无法启动）');
  }

  /// 应用退出时清理自己启动的 sidecar 进程。
  Future<void> stop() async {
    if (_stopping) return;
    _stopping = true;
    final p = _process;
    _process = null;
    if (p != null && p.pid > 0) {
      try {
        p.kill();
        await p.exitCode.timeout(const Duration(seconds: 3), onTimeout: () => -1);
        debugPrint('sidecar 已停止（pid=${p.pid}）');
      } catch (_) {
        // 进程可能已退出
      }
    }
  }
}

/// 表格编辑器页面 — Univer(WebView2) 打开/新建/编辑 xlsx，保存到 sidecar。
///
/// 保存走 /api/files/xlsx（base64），随后 sidecar 的 watchdog 自动增量索引，
/// 之后可在知识库问答中精确命中单号/金额。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:spring_note/core/services/sidecar_client.dart';
import 'package:spring_note/core/services/sidecar_lifecycle.dart';
import 'package:spring_note/core/theme/app_theme.dart';
import 'package:spring_note/features/sheets/univer_sheet_widget.dart';

/// Univer 前端入口。
/// 优先走 sidecar 本地 HTTP（/univer，ES module 无法从 file:// 加载），
/// sidecar 不可用时回退 file://（开发/演示）。
String defaultUniverHtmlUrl() {
  final base = SidecarClient().baseUrl;
  final viaHttp = '$base/univer/index.html';
  if (base.startsWith('http://')) {
    return viaHttp;
  }
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final bundled =
      '$exeDir${Platform.pathSeparator}univer_app${Platform.pathSeparator}dist${Platform.pathSeparator}index.html';
  if (File(bundled).existsSync()) {
    return 'file:///${bundled.replaceAll('\\', '/')}';
  }
  final dev = 'D:/XiaoYu/XiaoYuNote/spring_note/univer_app/dist/index.html';
  return 'file:///$dev';
}

class SheetEditorPage extends StatefulWidget {
  const SheetEditorPage({
    super.key,
    this.path,
    this.client,
    this.htmlUrl = defaultUniverHtmlUrl,
    this.initialBase64,
  });

  /// 打开的 xlsx 相对路径（sidecar 数据目录内）；null = 新建。
  final String? path;

  /// 可注入的 sidecar 客户端（测试用）。
  final SidecarClient? client;

  /// Univer 前端入口（file://）。
  final String Function() htmlUrl;

  /// 预加载的 xlsx base64（避免二次读取；为空则走 client.readXlsx）。
  final String? initialBase64;

  @override
  State<SheetEditorPage> createState() => _SheetEditorPageState();
}

class _SheetEditorPageState extends State<SheetEditorPage> {
  final GlobalKey<UniverSheetWidgetState> _sheetKey = GlobalKey<UniverSheetWidgetState>();
  UniverSheetWidgetState? _sheetState;
  SidecarClient? _client;
  String? _currentPath;
  String? _status;
  bool _saving = false;
  String? _univerUrl;

  @override
  void initState() {
    super.initState();
    _currentPath = widget.path;
    _client = widget.client ?? SidecarClient();
    if (widget.client == null) {
      // 真实运行：加载连接信息 + 等待 sidecar 就绪后再加载 WebView
      _initClient();
    } else if (_client!.isConfigured) {
      // 调用方（kb_page / notes_page）已 loadConnection：校验服务可达后加载，
      // 避免 sidecar 进程未就绪时 WebView 加载必失败的 URL → 白屏。
      _initClientWithConfigured();
    } else {
      // 测试注入且未配置：直接采用其 baseUrl（测试约定已预置就绪）
      _univerUrl = '${widget.client!.baseUrl}/univer/index.html';
    }
  }

  Future<void> _initClientWithConfigured() async {
    try {
      await _ensureSidecarReady();
      if (!mounted) return;
      setState(() => _univerUrl = '${_client!.baseUrl}/univer/index.html');
    } catch (e) {
      if (mounted) setState(() => _status = 'sidecar 未连接：$e');
    }
  }

  Future<void> _initClient() async {
    try {
      await _loadConnectionWithStartup();
      // loadConnection 只读取 .sidecar.json 配置文件，不保证 sidecar 进程已就绪。
      // 若此时直接设置 _univerUrl，WebView 会去加载一个连接被拒的地址 → 白屏。
      // 因此先探测 /api/health，不可达则确保启动 sidecar 并轮询等待就绪。
      await _ensureSidecarReady();
      if (!mounted) return;
      setState(() => _univerUrl = '${_client!.baseUrl}/univer/index.html');
    } catch (e) {
      if (mounted) setState(() => _status = 'sidecar 未连接：$e');
    }
  }

  /// 加载 sidecar 连接信息；若配置文件尚不存在，先拉起 sidecar 等待其生成再读取。
  Future<void> _loadConnectionWithStartup() async {
    try {
      await _client!.loadConnection();
    } catch (_) {
      // 尚无 .sidecar.json：可能是应用刚启动、sidecar 进程尚未生成配置。
      // SidecarLifecycle.start() 幂等：已有实例则复用，否则启动新进程。
      await SidecarLifecycle.instance.start();
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline)) {
        try {
          await _client!.loadConnection();
          return;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
      throw const SidecarUnavailableException('sidecar 配置尚未生成（等待超时）');
    }
  }

  /// 确保 sidecar 服务真正可达（否则 WebView 加载必失败，表现为空白页）。
  Future<void> _ensureSidecarReady() async {
    // 再次调用幂等：sidecar 进程已在跑则复用，否则拉起（防止 _loadConnectionWithStartup
    // 成功但进程恰好在启动间隙未监听端口的竞态）。
    await SidecarLifecycle.instance.start();
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      try {
        await _client!.health().timeout(const Duration(seconds: 2));
        return;
      } catch (_) {
        // sidecar 仍在启动（或刚启动完尚未监听端口）：短暂等待后重试
        if (mounted) setState(() => _status = '正在启动表格服务…');
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    throw const SidecarUnavailableException('sidecar 服务未就绪（等待超时）');
  }

  Future<void> _onSheetReady() async {
    // 从 GlobalKey 获取表格组件 state（WebView 已加载完成）
    // onReady 已延迟到下一帧，通常 currentState 可用；再兜底重试一次
    var sheet = _sheetKey.currentState;
    if (sheet == null) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      sheet = _sheetKey.currentState;
    }
    _sheetState = sheet;
    final path = widget.path;
    if (path == null) return;
    try {
      // 校验表格组件就绪（若 null，loadXlsx 会静默失败 → 显示空白表格）
      final sheet = _sheetState;
      if (sheet == null) {
        if (mounted) {
          setState(() => _status = '表格组件未就绪，请重试');
        }
        return;
      }
      String? base64 = widget.initialBase64;
      if (base64 == null || base64.isEmpty) {
        final data = await _client!.readXlsx(path);
        base64 = data['content_base64'] as String?;
      }
      if (base64 == null || base64.isEmpty) {
        if (mounted) {
          setState(() {
            _status = '文件为空或不可读';
          });
        }
        return;
      }
      await sheet.loadXlsx(base64);
      if (mounted) {
        setState(() => _status = '已打开 $path');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = '读取失败：$e';
        });
      }
    }
  }

  Future<void> _save() async {
    final sheet = _sheetState;
    if (sheet == null || _saving) return;
    setState(() {
      _saving = true;
      _status = '保存中…';
    });
    try {
      final base64 = await sheet.saveXlsx();
      if (base64 == null) throw const UniverSheetException('导出结果为空');
      var path = _currentPath;
      if (path == null) {
        // 新建表格：由用户指定相对路径（数据目录内）
        final chosen = await _promptNewPath();
        if (chosen == null || chosen.isEmpty) {
          if (mounted) setState(() => _status = '已取消保存');
          return;
        }
        path = (chosen.toLowerCase().endsWith('.xlsx') ||
                chosen.toLowerCase().endsWith('.xls'))
            ? chosen
            : '$chosen.xlsx';
      }
      await _client!.writeXlsx(path, base64);
      if (mounted) {
        setState(() {
          _currentPath = path;
          _status = '已保存到 $path（自动索引中…）';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _status = '保存失败：$e');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 新建表格时让用户输入保存的相对路径（相对 sidecar 数据目录）。
  Future<String?> _promptNewPath() async {
    final controller = TextEditingController(
      text: _defaultNewPath(),
    );
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('保存为新表格'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '相对路径（数据目录内，自动补 .xlsx）',
            hintText: '个人/2026-08-07/对账清单.xlsx',
            isDense: true,
          ),
          onSubmitted: (value) => Navigator.pop(ctx, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    return result;
  }

  String _defaultNewPath() {
    final now = DateTime.now();
    final mm = now.month.toString().padLeft(2, '0');
    final dd = now.day.toString().padLeft(2, '0');
    return '个人/${now.year}-$mm-$dd/新建表格.xlsx';
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colors(context);
    final url = _univerUrl;
    return Scaffold(
      backgroundColor: colors.background,
      body: Column(
        children: [
          _buildToolbar(colors),
          const Divider(height: 1),
          Expanded(
            child: url == null
                ? Center(
                    child: _status == null
                        ? const CircularProgressIndicator()
                        : Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              _status!,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 13,
                                color: colors.textMuted,
                              ),
                            ),
                          ),
                  )
                : UniverSheetWidget(
                    key: _sheetKey,
                    htmlUrl: url,
                    onReady: _onSheetReady,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(SpringThemeColors colors) {
    return Container(
      color: colors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: '返回',
            onPressed: () => Navigator.pop(context),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.note_add_outlined),
            tooltip: '新建表格',
            onPressed: () {
              _currentPath = null;
              _sheetState?.newSheet();
              setState(() => _status = '新建表格（保存时选择路径）');
            },
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_outlined, size: 16),
            label: Text(_saving ? '保存中…' : '保存'),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              _status ?? (_currentPath ?? '新建表格'),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: colors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// 表格编辑器页面 — Univer(WebView2) 打开/新建/编辑 xlsx。
///
/// 保存走 KbRustClient（Rust bridge，xlsx base64），随后 Rust 层增量索引，
/// 之后可在知识库问答中精确命中单号/金额。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:spring_note/core/services/kb_rust_client.dart';
import 'package:spring_note/core/theme/app_theme.dart';
import 'package:spring_note/features/sheets/univer_sheet_widget.dart';

/// Univer 前端入口。
/// 用 Rust 内置静态 HTTP 服务器托管（ES module 需要 http:// 协议，
/// file:// 会被浏览器 CORS 拦截）。服务器在 app 启动时预启动（见 app.dart），
/// 这里只读取缓存 URL；未就绪时回退 file://（可能因 CORS 失败）。
String defaultUniverHtmlUrl() {
  final base = univerServerBaseUrl;
  if (base != null && base.isNotEmpty) {
    return '$base/index.html';
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

/// Rust 静态服务器缓存 URL（app 启动时设置）。
String? univerServerBaseUrl;

class SheetEditorPage extends StatefulWidget {
  const SheetEditorPage({
    super.key,
    this.path,
    this.client,
    this.htmlUrl = defaultUniverHtmlUrl,
    this.initialBase64,
  });

  /// 打开的 xlsx 相对路径（数据目录内）；null = 新建。
  final String? path;

  /// 可注入的 Rust 客户端（测试用）。
  final KbRustClient? client;

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
  KbRustClient? _client;
  String? _currentPath;
  String? _status;
  bool _saving = false;
  String? _univerUrl;

  @override
  void initState() {
    super.initState();
    _currentPath = widget.path;
    _client = widget.client ??
        KbRustClient(dataDir: KbRustClient.defaultDataDir ?? '');
    // Rust 客户端本地直读，无需等待服务就绪；直接加载 Univer
    _univerUrl = widget.htmlUrl();
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
        final read = await _client!.readXlsx(path);
        base64 = read.isEmpty ? null : read;
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

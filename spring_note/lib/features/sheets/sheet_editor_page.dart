/// 表格编辑器页面 — Univer(WebView2) 打开/新建/编辑 xlsx，保存到 sidecar。
///
/// 保存走 /api/files/xlsx（base64），随后 sidecar 的 watchdog 自动增量索引，
/// 之后可在知识库问答中精确命中单号/金额。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:spring_note/core/services/sidecar_client.dart';
import 'package:spring_note/core/theme/app_theme.dart';
import 'package:spring_note/features/sheets/univer_sheet_widget.dart';

/// Univer 前端入口（file://）。
/// 打包后：exe 同目录 univer_app/dist/index.html；开发期：仓库内构建产物。
String defaultUniverHtmlUrl() {
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
  });

  /// 打开的 xlsx 相对路径（sidecar 数据目录内）；null = 新建。
  final String? path;

  /// 可注入的 sidecar 客户端（测试用）。
  final SidecarClient? client;

  /// Univer 前端入口（file://）。
  final String Function() htmlUrl;

  @override
  State<SheetEditorPage> createState() => _SheetEditorPageState();
}

class _SheetEditorPageState extends State<SheetEditorPage> {
  UniverSheetWidgetState? _sheetState;
  SidecarClient? _client;
  String? _currentPath;
  String? _status;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _currentPath = widget.path;
    _client = widget.client ?? SidecarClient();
    if (_client!.isConfigured == false && widget.client != null) {
      // 注入的 client 已带 token，无需加载
    } else if (widget.client == null) {
      _initClient();
    }
  }

  Future<void> _initClient() async {
    try {
      await _client!.loadConnection();
    } catch (e) {
      if (mounted) setState(() => _status = 'sidecar 未连接：$e');
    }
  }

  Future<void> _onSheetReady() async {
    final path = widget.path;
    if (path == null) return;
    try {
      final data = await _client!.readXlsx(path);
      final base64 = data['content_base64'] as String?;
      if (base64 == null || base64.isEmpty) {
        if (mounted) {
          setState(() {
            _status = '文件为空或不可读';
          });
        }
        return;
      }
      await _sheetState?.loadXlsx(base64);
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
      final path = _currentPath ?? _defaultNewPath();
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

  String _defaultNewPath() {
    final now = DateTime.now();
    final mm = now.month.toString().padLeft(2, '0');
    final dd = now.day.toString().padLeft(2, '0');
    return '个人/${now.year}-$mm-$dd/新建表格.xlsx';
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colors(context);
    return Scaffold(
      backgroundColor: colors.background,
      body: Column(
        children: [
          _buildToolbar(colors),
          const Divider(height: 1),
          Expanded(
            child: UniverSheetWidget(
              htmlUrl: widget.htmlUrl(),
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

/// 知识库面板 — 文件树（双区）+ 索引状态 + SSE 流式问答。
///
/// 数据全部来自 Python sidecar（SidecarClient，127.0.0.1 + token）：
///   /api/files/tree /api/health /api/stats /api/ask(SSE) /api/sheets
/// 问答支持流式渲染与引用点击（跳转文件预览）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:spring_note/core/services/sidecar_client.dart';
import 'package:spring_note/features/sheets/sheet_editor_page.dart';
import 'package:spring_note/core/theme/app_theme.dart';

/// 问答消息（用户 / AI 文本 / 系统状态）。
class _ChatMsg {
  final bool fromUser;
  final String text;
  final List<Map<String, dynamic>> refs;
  final bool streaming;

  const _ChatMsg(this.fromUser, this.text, {this.refs = const [], this.streaming = false});
}

/// 知识库数据源抽象（便于测试注入与 sidecar 解耦）。
abstract class KbDataSource {
  Future<Map<String, dynamic>> health();
  Future<Map<String, dynamic>> stats();
  Future<Map<String, dynamic>> filesTree();
  Future<Map<String, dynamic>> index();
  Future<String> readText(String path);
  Stream<SidecarAskEvent> askStream(String query, {int? k, String? path});
}

/// 真实实现：包装 SidecarClient（自动加载连接）。
class SidecarKbDataSource implements KbDataSource {
  SidecarKbDataSource({SidecarClient? client}) : _client = client ?? SidecarClient();

  final SidecarClient _client;
  bool _loaded = false;

  Future<void> _ensureLoaded() async {
    if (!_loaded) {
      if (!_client.isConfigured) {
        await _client.loadConnection();
      }
      _loaded = true;
    }
  }

  @override
  Future<Map<String, dynamic>> health() async {
    await _ensureLoaded();
    return _client.health();
  }

  @override
  Future<Map<String, dynamic>> stats() async {
    await _ensureLoaded();
    return _client.stats();
  }

  @override
  Future<Map<String, dynamic>> filesTree() async {
    await _ensureLoaded();
    return _client.filesTree();
  }

  @override
  Future<Map<String, dynamic>> index() async {
    await _ensureLoaded();
    return _client.index();
  }

  @override
  Future<String> readText(String path) async {
    await _ensureLoaded();
    return _client.readText(path);
  }

  @override
  Stream<SidecarAskEvent> askStream(String query, {int? k, String? path}) async* {
    await _ensureLoaded();
    yield* _client.askStream(query, k: k, path: path);
  }
}

class KbPage extends StatefulWidget {
  const KbPage({super.key, this.dataSource});

  /// 可注入的数据源（测试用）；为空时使用 sidecar 真实数据源。
  final KbDataSource? dataSource;

  @override
  State<KbPage> createState() => _KbPageState();
}

class _KbPageState extends State<KbPage> {
  KbDataSource? _dataSource;
  String? _error;
  bool _loading = true;

  Map<String, dynamic>? _health;
  Map<String, dynamic>? _stats;
  Map<String, dynamic>? _tree;
  bool _indexing = false;

  final List<_ChatMsg> _messages = [];
  final TextEditingController _queryController = TextEditingController();
  bool _asking = false;
  String _streamText = '';
  List<Map<String, dynamic>> _streamRefs = [];
  StreamSubscription<SidecarAskEvent>? _askSub;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _askSub?.cancel();
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _dataSource = widget.dataSource ?? SidecarKbDataSource();
      await _refreshAll();
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refreshAll() async {
    final ds = _dataSource;
    if (ds == null) return;
    final health = await ds.health();
    Map<String, dynamic>? stats;
    Map<String, dynamic>? tree;
    try {
      stats = await ds.stats();
      tree = await ds.filesTree();
    } catch (_) {
      // stats/tree 失败不阻塞整体
    }
    if (mounted) {
      setState(() {
        _health = health;
        _stats = stats;
        _tree = tree;
      });
    }
  }

  Future<void> _runIndex() async {
    final ds = _dataSource;
    if (ds == null) return;
    setState(() => _indexing = true);
    try {
      await ds.index();
      await _refreshAll();
      _appendStatus('索引完成');
    } catch (e) {
      _appendStatus('索引失败：$e');
    } finally {
      if (mounted) setState(() => _indexing = false);
    }
  }

  void _appendStatus(String text) {
    if (!mounted) return;
    setState(() => _messages.add(_ChatMsg(false, text)));
  }

  Future<void> _ask() async {
    final ds = _dataSource;
    final q = _queryController.text.trim();
    if (ds == null || q.isEmpty || _asking) return;

    setState(() {
      _messages.add(_ChatMsg(true, q));
      _queryController.clear();
      _asking = true;
      _streamText = '';
      _streamRefs = [];
    });

    _askSub?.cancel();
    _askSub = ds.askStream(q).listen(
      (event) {
        if (!mounted) return;
        switch (event.type) {
          case 'answer':
            _streamText += event.data['text'] as String? ?? '';
            _updateStreaming();
          case 'retrieved':
            final chunks = event.data['chunks'] as List? ?? [];
            _streamRefs = chunks.cast<Map<String, dynamic>>();
            _updateStreaming();
          case 'done':
            final refs = (event.data['refs'] as List?)?.cast<Map<String, dynamic>>() ?? [];
            setState(() {
              final last = _messages.isNotEmpty ? _messages.last : null;
              final complete = _ChatMsg(false, _streamText, refs: refs);
              if (last != null && last.streaming) {
                _messages[_messages.length - 1] = complete; // 替换流式占位
              } else {
                _messages.add(complete);
              }
              _asking = false;
              _streamText = '';
              _streamRefs = [];
            });
          case 'error':
            setState(() {
              final last = _messages.isNotEmpty ? _messages.last : null;
              final err = _ChatMsg(false, '错误：${event.data['message']}');
              if (last != null && last.streaming) {
                _messages[_messages.length - 1] = err;
              } else {
                _messages.add(err);
              }
              _asking = false;
              _streamText = '';
              _streamRefs = [];
            });
          default:
            break;
        }
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _messages.add(_ChatMsg(false, '请求失败：$e'));
          _asking = false;
        });
      },
    );
  }

  void _updateStreaming() {
    if (!mounted) return;
    setState(() {
      if (_messages.isNotEmpty && _messages.last.streaming) {
        _messages[_messages.length - 1] =
            _ChatMsg(false, _streamText, refs: _streamRefs, streaming: true);
      } else {
        _messages.add(_ChatMsg(false, _streamText, refs: _streamRefs, streaming: true));
      }
    });
  }

  Future<void> _openRef(String source) async {
    if (source.endsWith('.xlsx') || source.endsWith('.xls')) {
      final client = SidecarClient();
      try {
        await client.loadConnection();
      } catch (_) {
        _appendStatus('sidecar 未连接，无法打开表格');
        return;
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SheetEditorPage(path: source, client: client),
        ),
      );
      return;
    }
    final ds = _dataSource;
    if (ds == null) return;
    if (!source.endsWith('.md') && !source.endsWith('.txt')) {
      _appendStatus('「$source」请用表格/文档模块打开');
      return;
    }
    try {
      final content = await ds.readText(source);
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(source),
          content: SizedBox(
            width: 560,
            height: 400,
            child: SingleChildScrollView(
              child: Text(content, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          ],
        ),
      );
    } catch (e) {
      _appendStatus('读取失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colors(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null || _dataSource == null) {
      return _buildUnavailable(colors);
    }
    return Row(
      children: [
        SizedBox(width: 280, child: _buildFileTree(colors)),
        VerticalDivider(width: 1, color: colors.border),
        Expanded(
          child: Column(
            children: [
              _buildStatusBar(colors),
              const Divider(height: 1),
              Expanded(child: _buildChat(colors)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildUnavailable(SpringThemeColors colors) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off, size: 56, color: colors.textMuted),
          const SizedBox(height: 12),
          Text('sidecar 未连接', style: TextStyle(color: colors.textMuted, fontSize: 16)),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              _error ?? '请先启动 Python 侧车服务（python -m sidecar）',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textMuted, fontSize: 12),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _init, child: const Text('重试')),
        ],
      ),
    );
  }

  Widget _buildFileTree(SpringThemeColors colors) {
    final tree = _tree;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Row(
            children: [
              Text('文件', style: TextStyle(color: colors.textMuted, fontSize: 12)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh, size: 16),
                tooltip: '刷新',
                onPressed: _refreshAll,
              ),
            ],
          ),
        ),
        Expanded(
          child: tree == null
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  child: _TreeNodeView(
                    node: tree,
                    onFileTap: (path) => _openRef(path),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildStatusBar(SpringThemeColors colors) {
    final health = _health;
    final stats = _stats;
    final files = stats?['files'] ?? 0;
    final chunks = stats?['chunks'] ?? 0;
    final cells = stats?['cells'] ?? 0;
    final llmReady = health?['llm_ready'] == true;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _StatusPill(icon: Icons.description_outlined, label: '文件 $files'),
          _StatusPill(icon: Icons.grid_view_outlined, label: '块 $chunks'),
          _StatusPill(icon: Icons.table_chart_outlined, label: '单元格 $cells'),
          _StatusPill(
            icon: llmReady ? Icons.check_circle : Icons.error_outline,
            label: llmReady ? 'LLM 就绪' : 'LLM 未配置',
            color: llmReady ? const Color(0xFF059669) : const Color(0xFFDC2626),
          ),
          OutlinedButton.icon(
            onPressed: _indexing ? null : _runIndex,
            icon: _indexing
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync, size: 16),
            label: Text(_indexing ? '索引中…' : '立即索引'),
          ),
        ],
      ),
    );
  }

  Widget _buildChat(SpringThemeColors colors) {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _messages.length + (_asking ? 0 : 0),
            itemBuilder: (context, i) => _ChatBubble(
              msg: _messages[i],
              colors: colors,
              onRefTap: _openRef,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _queryController,
                  enabled: !_asking,
                  decoration: InputDecoration(
                    hintText: '问知识库（支持单号/金额精确命中）…',
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  onSubmitted: (_) => _ask(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _asking ? null : _ask,
                child: Text(_asking ? '…' : '问'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colors(context);
    final c = color ?? colors.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: c),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 12, color: c)),
        ],
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.msg, required this.colors, required this.onRefTap});

  final _ChatMsg msg;
  final SpringThemeColors colors;
  final ValueChanged<String> onRefTap;

  @override
  Widget build(BuildContext context) {
    final bubble = Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: msg.fromUser ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12) : colors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            msg.text.isEmpty ? (msg.streaming ? '…' : '') : msg.text,
            style: const TextStyle(fontSize: 14, height: 1.5),
          ),
          if (msg.refs.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final ref in msg.refs)
                  ActionChip(
                    label: Text(
                      _refLabel(ref),
                      style: const TextStyle(fontSize: 11),
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      final source = ref['source'] ?? ref['rel_path'] ?? '';
                      if (source is String && source.isNotEmpty) onRefTap(source);
                    },
                  ),
              ],
            ),
          ],
        ],
      ),
    );
    return Align(
      alignment: msg.fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: bubble),
    );
  }

  String _refLabel(Map<String, dynamic> ref) {
    final source = (ref['source'] ?? ref['rel_path'] ?? '').toString();
    final score = ref['score'];
    if (score != null) return '$source (${score.toStringAsFixed(2)})';
    return source;
  }
}

class _TreeNodeView extends StatefulWidget {
  const _TreeNodeView({required this.node, required this.onFileTap, this.pathPrefix = ''});

  final Map<String, dynamic> node;
  final ValueChanged<String> onFileTap;
  final String pathPrefix;

  @override
  State<_TreeNodeView> createState() => _TreeNodeViewState();
}

class _TreeNodeViewState extends State<_TreeNodeView> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colors(context);
    final name = widget.node['name'] as String? ?? '';
    final type = widget.node['type'] as String? ?? 'dir';
    final children = (widget.node['children'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final path = widget.pathPrefix.isEmpty ? name : '${widget.pathPrefix}/$name';

    if (type == 'file') {
      return InkWell(
        onTap: () => widget.onFileTap(path),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Row(
            children: [
              const Icon(Icons.insert_drive_file_outlined, size: 14),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(
              children: [
                Icon(
                  _expanded ? Icons.folder_open : Icons.folder,
                  size: 15,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                ),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: colors.textMuted,
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(left: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final child in children)
                  _TreeNodeView(node: child, onFileTap: widget.onFileTap, pathPrefix: path),
              ],
            ),
          ),
      ],
    );
  }
}

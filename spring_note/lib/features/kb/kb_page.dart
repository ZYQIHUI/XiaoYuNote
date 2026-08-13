/// 知识库面板 — 文件树（双区）+ 索引状态 + SSE 流式问答。
///
/// 数据全部来自 Python sidecar（SidecarClient，127.0.0.1 + token）：
///   /api/files/tree /api/health /api/stats /api/ask(SSE) /api/sheets
/// 问答支持流式渲染与引用点击（跳转文件预览）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:spring_note/core/services/external_link_service.dart';
import 'package:spring_note/core/services/kb_rust_client.dart';
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
  Future<Map<String, dynamic>> config();
  Future<String> readText(String path);
  Stream<SidecarAskEvent> askStream(String query, {int? k, String? path});
}

/// 真实实现：包装 KbRustClient（替代原 sidecar HTTP 调用）。
class SidecarKbDataSource implements KbDataSource {
  SidecarKbDataSource({KbRustClient? client, String? dataDir})
      : _client = client ?? KbRustClient(dataDir: dataDir ?? '');

  final KbRustClient _client;

  @override
  Future<Map<String, dynamic>> health() async {
    return {'status': 'ok', 'llm_ready': true, 'index': {}};
  }

  @override
  Future<Map<String, dynamic>> filesTree() => _client.filesTree();

  @override
  Future<Map<String, dynamic>> stats() => _client.stats();

  @override
  Future<Map<String, dynamic>> index() => _client.index();

  @override
  Future<Map<String, dynamic>> config() async => {};

  @override
  Future<String> readText(String path) => _client.readText(path);

  @override
  Stream<SidecarAskEvent> askStream(String query, {int? k, String? path}) async* {
    // 非流式：调用 Rust kb_ask，返回单个 answer 事件
    yield const SidecarAskEvent('status', {'message': '检索中…'});
    try {
      final result = await _client.ask(
        query: query,
        k: k,
        path: path,
        embedBaseUrl: '',
        embedApiKey: '',
        embedModel: '',
        answer: '', // 先留空，后续接入 LLM
      );
      final answer = result['answer'] as String? ?? '';
      final refs = (result['references_json'] as String?) ?? '[]';
      yield SidecarAskEvent('answer', {'text': answer, 'references': refs});
      yield const SidecarAskEvent('done', {});
    } catch (e) {
      yield SidecarAskEvent('error', {'message': e.toString()});
    }
  }
}

class KbPage extends StatefulWidget {
  const KbPage({super.key, this.dataSource, this.onOpenFileInNotes});

  /// 可注入的数据源（测试用）；为空时使用 sidecar 真实数据源。
  final KbDataSource? dataSource;

  /// 引用点击时跳转便签页打开文件（由 app_shell 注入）。
  final ValueChanged<String>? onOpenFileInNotes;

  @override
  State<KbPage> createState() => _KbPageState();
}

class _KbPageState extends State<KbPage> {
  KbDataSource? _dataSource;
  String? _error;
  bool _loading = true;

  // 重试定时器（dispose 时取消，避免测试/销毁后残留 pending timer）
  Timer? _retryTimer;

  Map<String, dynamic>? _health;
  Map<String, dynamic>? _stats;
  Map<String, dynamic>? _config;
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
    _retryTimer?.cancel();
    _retryTimer = null;
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
      _dataSource = widget.dataSource ?? SidecarKbDataSource(
        dataDir: KbRustClient.defaultDataDir ?? '',
      );
      // sidecar 首次启动需要几秒，自动重试（最多 ~8s），避免必须手动点重试
      var lastError = '初始化失败';
      for (var attempt = 0; attempt < 6; attempt++) {
        if (!mounted) return;
        try {
          await _refreshAll();
          lastError = '';
          break;
        } catch (e) {
          lastError = e.toString();
          if (attempt < 5) {
            // 用可取消 Timer 替代 Future.delayed：组件销毁时立即停止重试，
            // 避免测试/退出后残留 pending timer（flutter_test 会断言 !timersPending）。
            final completer = Completer<void>();
            _retryTimer?.cancel();
            _retryTimer = Timer(const Duration(milliseconds: 1500), () {
              if (!completer.isCompleted) completer.complete();
            });
            await completer.future;
          }
        }
      }
      if (lastError.isNotEmpty && mounted) {
        _error = lastError;
      }
    } catch (e) {
      if (mounted) _error = e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refreshAll() async {
    final ds = _dataSource;
    if (ds == null) return;
    final health = await ds.health();
    Map<String, dynamic>? stats;
    Map<String, dynamic>? config;
    try {
      stats = await ds.stats();
      config = await ds.config();
    } catch (_) {
      // stats/config 失败不阻塞整体
    }
    if (mounted) {
      setState(() {
        _health = health;
        _stats = stats;
        _config = config;
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

  /// 用系统文件管理器打开知识库数据目录。
  Future<void> _openFolder() async {
    final dataDir = KbRustClient.defaultDataDir;
    if (dataDir == null || dataDir.isEmpty) {
      _appendStatus('无法获取知识库目录');
      return;
    }
    final ok = await const ExternalLinkService().openFolder(dataDir);
    if (!ok && mounted) {
      _appendStatus('打开文件夹失败：$dataDir');
    }
  }

  Future<void> _openRef(String source) async {
    // 优先跳转便签页打开（知识库专注问答，看文件去便签）
    final openInNotes = widget.onOpenFileInNotes;
    if (openInNotes != null) {
      openInNotes(source);
      return;
    }
    if (source.endsWith('.xlsx') || source.endsWith('.xls')) {
      final client = KbRustClient(dataDir: KbRustClient.defaultDataDir ?? '');
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
        SizedBox(width: 280, child: _buildKbScope(colors)),
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
          Text('知识库未就绪', style: TextStyle(color: colors.textMuted, fontSize: 16)),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              _error ?? '请先在设置中配置 AI 供应商，然后点击「立即索引」',
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

  /// 知识库范围：仅文件夹路径列表（告诉 LLM 知识库覆盖哪些位置）。
  Widget _buildKbScope(SpringThemeColors colors) {
    final health = _health;
    final dataDir = health?['data_dir'] as String? ?? '';
    final config = _config;
    final sources = (config?['sources'] as List? ?? []).cast<String>();
    final extraSources = (config?['extra_sources'] as List? ?? []).cast<String>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Row(
            children: [
              Text('知识库范围', style: TextStyle(color: colors.textMuted, fontSize: 12)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.folder_open_outlined, size: 16),
                tooltip: '打开数据目录',
                onPressed: _openFolder,
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 16),
                tooltip: '刷新',
                onPressed: _refreshAll,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            dataDir.isEmpty ? '数据目录：未知' : '数据目录：$dataDir',
            style: TextStyle(fontSize: 11, color: colors.textMuted),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 6),
            children: [
              for (final s in sources)
                if (s.isNotEmpty)
                  _ScopePathTile(icon: Icons.folder_outlined, path: s),
              if (extraSources.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                  child: Text(
                    '外部文件夹',
                    style: TextStyle(fontSize: 11, color: colors.textMuted),
                  ),
                ),
                for (final s in extraSources)
                  _ScopePathTile(icon: Icons.folder_special_outlined, path: s),
              ],
              if (sources.isEmpty && extraSources.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '暂无知识库文件夹，请到「设置 → 知识库文件夹」添加',
                    style: TextStyle(fontSize: 12, color: colors.textMuted),
                  ),
                ),
            ],
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

class _ScopePathTile extends StatelessWidget {
  const _ScopePathTile({required this.icon, required this.path});

  final IconData icon;
  final String path;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Row(
        children: [
          Icon(icon, size: 15, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              path,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
        ],
      ),
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
    // 外部源节点携带绝对 path；数据目录内节点由 pathPrefix 拼接相对路径
    final nodePath = widget.node['path'] as String?;
    final path = nodePath ?? (widget.pathPrefix.isEmpty ? name : '${widget.pathPrefix}/$name');

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
/// 知识库文件树面板（便签页主界面左侧）。
///
/// 顶部：目录路径下拉（切换任意根目录）+ 新建按钮
/// 主体：VS Code 风格文件树（紧凑、hover 高亮、缩进线、右键删除/新建）
/// 回调：onOpenFile(path) —— 由宿主决定如何打开（md 用便签编辑器，xlsx 用表格）
library;

import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:spring_note/core/services/sidecar_client.dart';
import 'package:spring_note/core/theme/app_theme.dart';
import 'package:spring_note/features/kb/kb_page.dart' show KbDataSource;

/// 可注入的数据源（测试用）。
abstract class KbFileDataSource {
  Future<Map<String, dynamic>> dirs();
  Future<Map<String, dynamic>> filesTreeRoot(String root);
  Future<String> readText(String path);
  Future<void> writeText(String path, String content);
  Future<Map<String, dynamic>> readXlsx(String path);
  Future<void> createFile(String path, {String content = ''});
  Future<void> createDir(String path);
  Future<void> delete(String path);

  /// 把文件夹加入可浏览工作区（sidecar extra_sources），文件树即可浏览/编辑。
  Future<void> addSource(String path);
}

class SidecarKbFileDataSource implements KbFileDataSource {
  SidecarKbFileDataSource({SidecarClient? client}) : _client = client ?? SidecarClient();

  final SidecarClient _client;
  bool _loaded = false;

  Future<void> _ensure() async {
    if (_loaded) return;
    await _client.loadConnection();
    _loaded = true;
  }

  @override
  Future<Map<String, dynamic>> dirs() async {
    await _ensure();
    return _client.dirs();
  }

  @override
  Future<Map<String, dynamic>> filesTreeRoot(String root) async {
    await _ensure();
    return _client.filesTreeRoot(root);
  }

  @override
  Future<String> readText(String path) async {
    await _ensure();
    return _client.readText(path);
  }

  @override
  Future<void> writeText(String path, String content) async {
    await _ensure();
    await _client.writeText(path, content);
  }

  @override
  Future<Map<String, dynamic>> readXlsx(String path) async {
    await _ensure();
    return _client.readXlsx(path);
  }

  @override
  Future<void> createFile(String path, {String content = ''}) async {
    await _ensure();
    await _client.createFile(path, content: content);
  }

  @override
  Future<void> createDir(String path) async {
    await _ensure();
    await _client.createDir(path);
  }

  @override
  Future<void> delete(String path) async {
    await _ensure();
    await _client.deletePath(path);
  }

  @override
  Future<void> addSource(String path) async {
    await _ensure();
    // 读当前 extra_sources，追加后写回（避免覆盖已有配置）
    final cfg = await _client.config();
    final existing = (cfg['extra_sources'] as List? ?? []).map((e) => e.toString()).toList();
    if (existing.contains(path)) return;
    await _client.setConfig({'extra_sources': [...existing, path]});
  }
}

/// 将 kb_page 的 KbDataSource 适配为 KbFileDataSource（测试注入用）。
class KbFileTreeDataSourceAdapter implements KbFileDataSource {
  KbFileTreeDataSourceAdapter(this._inner);

  final KbDataSource _inner;

  @override
  Future<Map<String, dynamic>> dirs() async {
    final client = SidecarClient();
    await client.loadConnection();
    return client.dirs();
  }

  @override
  Future<Map<String, dynamic>> filesTreeRoot(String root) async {
    final client = SidecarClient();
    await client.loadConnection();
    return client.filesTreeRoot(root);
  }

  @override
  Future<String> readText(String path) => _inner.readText(path);

  @override
  Future<void> writeText(String path, String content) {
    final client = SidecarClient();
    return client.loadConnection().then((_) => client.writeText(path, content));
  }

  @override
  Future<Map<String, dynamic>> readXlsx(String path) {
    final client = SidecarClient();
    return client.loadConnection().then((_) => client.readXlsx(path));
  }

  @override
  Future<void> createFile(String path, {String content = ''}) {
    final client = SidecarClient();
    return client.loadConnection().then((_) => client.createFile(path, content: content));
  }

  @override
  Future<void> createDir(String path) {
    final client = SidecarClient();
    return client.loadConnection().then((_) => client.createDir(path));
  }

  @override
  Future<void> delete(String path) {
    final client = SidecarClient();
    return client.loadConnection().then((_) => client.deletePath(path));
  }

  @override
  Future<void> addSource(String path) {
    final client = SidecarClient();
    return client.loadConnection().then((_) async {
      final cfg = await client.config();
      final existing = (cfg['extra_sources'] as List? ?? []).map((e) => e.toString()).toList();
      if (existing.contains(path)) return;
      await client.setConfig({'extra_sources': [...existing, path]});
    });
  }
}

/// 文件树面板：目录切换 + 新建 + VS Code 风格树 + 右键菜单。
class KbFileTreePanel extends StatefulWidget {
  const KbFileTreePanel({
    super.key,
    this.dataSource,
    this.onOpenFile,
    this.openFileRequest,
  });

  final KbFileDataSource? dataSource;

  /// 选中文件时回调（md/txt/xlsx 由宿主决定如何打开）。
  final ValueChanged<String>? onOpenFile;

  /// 外部请求打开的文件（知识库引用跳转）；变化时自动打开。
  final String? openFileRequest;

  @override
  State<KbFileTreePanel> createState() => _KbFileTreePanelState();
}

class _KbFileTreePanelState extends State<KbFileTreePanel> {
  KbFileDataSource? _dataSource;
  bool _loading = true;
  String? _error;

  // 重试定时器（dispose 时取消，避免测试/销毁后残留 pending timer）
  Timer? _retryTimer;

  // 目录
  List<Map<String, dynamic>> _dirs = [];
  String _currentRoot = ''; // 相对数据目录路径或绝对路径
  Map<String, dynamic>? _tree;

  // 操作中
  bool _creating = false;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didUpdateWidget(covariant KbFileTreePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final request = widget.openFileRequest;
    if (request != null &&
        request.isNotEmpty &&
        request != oldWidget.openFileRequest &&
        _dataSource != null &&
        !_loading) {
      widget.onOpenFile?.call(request);
    }
  }

  Future<void> _init() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _dataSource = widget.dataSource ?? SidecarKbFileDataSource();
      // sidecar 首次启动需要几秒，自动重试（最多 ~8s）
      var lastError = '初始化失败';
      for (var attempt = 0; attempt < 6; attempt++) {
        if (!mounted) return;
        try {
          final dirsResp = await _dataSource!.dirs();
          _dirs = (dirsResp['dirs'] as List? ?? []).cast<Map<String, dynamic>>();
          if (_dirs.isNotEmpty) {
            _currentRoot = _dirs.first['root'] as String? ?? '';
          }
          await _loadTree();
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
      if (lastError.isNotEmpty && mounted) _error = lastError;
    } catch (e) {
      if (mounted) _error = e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _retryTimer = null;
    super.dispose();
  }

  Future<void> _loadTree() async {
    final ds = _dataSource;
    if (ds == null) return;
    try {
      final tree = await ds.filesTreeRoot(_currentRoot);
      if (mounted) setState(() => _tree = tree);
    } catch (e) {
      if (mounted) setState(() => _error = '加载目录失败：$e');
    }
  }

  Future<void> _switchRoot(String root) async {
    if (root == _currentRoot) return;
    setState(() {
      _currentRoot = root;
      _tree = null;
    });
    await _loadTree();
  }

  /// IDE 式「打开文件夹」：选择任意文件夹作为当前工作区根。
  /// 选中后加入 sidecar 可浏览工作区（extra_sources），文件树切换到该文件夹。
  Future<void> _openCurrentFolder() async {
    final ds = _dataSource;
    if (ds == null) return;
    final path = await getDirectoryPath(
      confirmButtonText: '打开文件夹',
    );
    if (path == null || path.trim().isEmpty) return;
    final folder = path.trim();
    try {
      await ds.addSource(folder);
      // 刷新目录列表并切换到新文件夹
      final dirsResp = await ds.dirs();
      if (!mounted) return;
      setState(() {
        _dirs = (dirsResp['dirs'] as List? ?? []).cast<Map<String, dynamic>>();
        _currentRoot = folder;
        _tree = null;
      });
      await _loadTree();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开文件夹失败：$e')),
        );
      }
    }
  }

  String _pathForNode(Map<String, dynamic> node, String parentPath) {
    final name = node['name'] as String? ?? '';
    final nodePath = node['path'] as String?;
    if (nodePath != null && nodePath.isNotEmpty) return nodePath;
    final relRoot = _tree?['rel_root'] as String?;
    if (relRoot != null && relRoot.isNotEmpty) {
      return parentPath.isEmpty ? '$relRoot/$name' : '$relRoot/$parentPath/$name';
    }
    return parentPath.isEmpty ? name : '$parentPath/$name';
  }

  /// 新建对话框：选择类型并输入名称，在当前目录创建。
  Future<void> _showCreateDialog([String? parentPath]) async {
    if (_creating) return;
    final controller = TextEditingController();
    String type = 'md';
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('新建'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '例如：会议纪要 / 新建文件夹',
                  isDense: true,
                ),
                onSubmitted: (v) => Navigator.pop(ctx, '$type|$v'),
              ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'md', label: Text('Markdown')),
                  ButtonSegment(value: 'txt', label: Text('文本')),
                  ButtonSegment(value: 'dir', label: Text('文件夹')),
                ],
                selected: {type},
                onSelectionChanged: (s) => setDialogState(() => type = s.first),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final name = controller.text.trim();
                if (name.isNotEmpty) Navigator.pop(ctx, '$type|$name');
              },
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (result == null) return;
    final parts = result.split('|');
    if (parts.length != 2) return;
    final t = parts[0];
    final name = parts[1].trim();
    if (name.isEmpty) return;
    final ds = _dataSource;
    if (ds == null) return;
    final relRoot = _tree?['rel_root'] as String? ?? '';
    final basePrefix = parentPath ?? relRoot;
    setState(() => _creating = true);
    try {
      if (t == 'dir') {
        final full = basePrefix.isEmpty ? name : '$basePrefix/$name';
        await ds.createDir(full);
      } else {
        final ext = t == 'md' ? '.md' : '.txt';
        final finalName = name.endsWith(ext) ? name : '$name$ext';
        final full = basePrefix.isEmpty ? finalName : '$basePrefix/$finalName';
        await ds.createFile(full);
      }
      if (mounted) {
        await _loadTree();
      }
    } catch (e) {
      if (mounted) setState(() => _error = '创建失败：$e');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  /// 删除文件/文件夹（带确认）。
  Future<void> _confirmDelete(String path, {required bool isDir}) async {
    if (_deleting) return;
    final ds = _dataSource;
    if (ds == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isDir ? '删除文件夹' : '删除文件'),
        content: Text('确定删除「$path」吗？${isDir ? '文件夹内容将全部删除。' : ''}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _deleting = true);
    try {
      await ds.delete(path);
      if (mounted) {
        await _loadTree();
      }
    } catch (e) {
      if (mounted) setState(() => _error = '删除失败：$e');
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colors(context);
    if (_loading) {
      return Container(
        width: 278,
        color: colors.sidebar,
        alignment: Alignment.center,
        child: const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null || _dataSource == null) {
      return Container(
        width: 278,
        color: colors.sidebar,
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off, size: 40, color: colors.textMuted),
            const SizedBox(height: 10),
            Text(
              'sidecar 未连接',
              style: TextStyle(color: colors.textMuted, fontSize: 14),
            ),
            const SizedBox(height: 6),
            Text(
              _error ?? '',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textMuted, fontSize: 11),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _init, child: const Text('重试')),
          ],
        ),
      );
    }
    return Container(
      width: 278,
      decoration: BoxDecoration(
        color: colors.sidebar,
        border: Border(right: BorderSide(color: colors.divider)),
      ),
      child: Column(
        children: [
          _buildTopBar(colors),
          const Divider(height: 1),
          Expanded(child: _buildFileTree(colors)),
        ],
      ),
    );
  }

  /// 顶部：目录路径下拉 + 新建 + 刷新。
  Widget _buildTopBar(SpringThemeColors colors) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: colors.sidebar,
      child: Row(
        children: [
          Icon(Icons.folder_outlined, size: 16, color: colors.textMuted),
          const SizedBox(width: 6),
          Expanded(
            child: _DirDropdown(
              dirs: _dirs,
              currentRoot: _currentRoot,
              onChanged: _switchRoot,
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.folder_open_outlined, size: 17),
            tooltip: '打开文件夹',
            onPressed: _openCurrentFolder,
          ),
          IconButton(
            icon: const Icon(Icons.create_new_folder_outlined, size: 17),
            tooltip: '新建',
            onPressed: _creating ? null : () => _showCreateDialog(),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 15),
            tooltip: '刷新',
            onPressed: _loadTree,
          ),
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
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 6),
          child: Text(
            '文件',
            style: TextStyle(
              color: colors.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
        ),
        Expanded(
          child: tree == null
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  child: _CodeTreeView(
                    // 用虚拟根（name 空）包裹真实子节点，避免根节点名进入文件路径；
                    // 虚拟根始终展开显示顶层目录，目录本身默认收起
                    node: {
                      'name': '',
                      'type': 'dir',
                      'children': tree['children'] ?? [],
                    },
                    initiallyExpanded: true,
                    onFileTap: (path) => widget.onOpenFile?.call(path),
                    onNewItem: _showCreateDialog,
                    onDelete: _confirmDelete,
                    pathOf: _pathForNode,
                  ),
                ),
        ),
      ],
    );
  }
}

/// 目录路径下拉。
class _DirDropdown extends StatelessWidget {
  const _DirDropdown({
    required this.dirs,
    required this.currentRoot,
    required this.onChanged,
  });

  final List<Map<String, dynamic>> dirs;
  final String currentRoot;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    // 分组：内置目录（数据目录/notes/业务区）+ 外部文件夹
    final builtin = <Map<String, dynamic>>[];
    final external = <Map<String, dynamic>>[];
    for (final d in dirs) {
      final root = d['root'] as String? ?? '';
      final isExternal = root.isNotEmpty && !root.startsWith('notes/') && !['个人', '小组', '文档', 'VDMS在线办公平台'].contains(root);
      (isExternal ? external : builtin).add(d);
    }
    final currentLabel = dirs
        .where((d) => (d['root'] as String? ?? '') == currentRoot)
        .map((d) => d['label'] as String? ?? '')
        .firstOrNull;

    return _FolderSelector(
      currentLabel: currentLabel ?? (currentRoot.isEmpty ? '数据目录' : currentRoot),
      currentRoot: currentRoot,
      builtinDirs: builtin,
      externalDirs: external,
      onChanged: onChanged,
    );
  }
}

/// 文件夹切换器：当前目录 + 分组下拉（内置目录 / 外部文件夹），当前项高亮。
class _FolderSelector extends StatelessWidget {
  const _FolderSelector({
    required this.currentLabel,
    required this.currentRoot,
    required this.builtinDirs,
    required this.externalDirs,
    required this.onChanged,
  });

  final String currentLabel;
  final String currentRoot;
  final List<Map<String, dynamic>> builtinDirs;
  final List<Map<String, dynamic>> externalDirs;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colors(context);
    return Tooltip(
      message: '切换文件夹',
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _showPicker(context),
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: colors.surfaceMuted,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Icon(Icons.folder_outlined, size: 15, color: colors.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  currentLabel,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: colors.text),
                ),
              ),
              Icon(Icons.keyboard_arrow_down, size: 16, color: colors.textMuted),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showPicker(BuildContext context) async {
    final colors = AppTheme.colors(context);
    final selected = await showMenu<String>(
      context: context,
      position: const RelativeRect.fromLTRB(16, 48, 16, 0),
      color: colors.surface,
      constraints: const BoxConstraints(maxWidth: 320),
      items: [
        if (builtinDirs.isNotEmpty) ...[
          const PopupMenuItem(
            enabled: false,
            child: Text('内置目录', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
          ),
          for (final d in builtinDirs)
            _folderMenuItem(context, d, colors),
        ],
        if (externalDirs.isNotEmpty) ...[
          const PopupMenuItem(
            enabled: false,
            child: Text('外部文件夹', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
          ),
          for (final d in externalDirs)
            _folderMenuItem(context, d, colors),
        ],
      ],
    );
    if (selected != null) {
      onChanged(selected);
    }
  }

  PopupMenuItem<String> _folderMenuItem(BuildContext context, Map<String, dynamic> d, SpringThemeColors colors) {
    final root = d['root'] as String? ?? '';
    final label = d['label'] as String? ?? '';
    final selected = root == currentRoot;
    return PopupMenuItem<String>(
      value: root,
      child: Row(
        children: [
          Icon(
            Icons.folder_outlined,
            size: 15,
            color: selected
                ? Theme.of(context).colorScheme.primary
                : colors.textMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                color: selected ? Theme.of(context).colorScheme.primary : colors.text,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
          if (selected)
            Icon(Icons.check, size: 15, color: Theme.of(context).colorScheme.primary),
        ],
      ),
    );
  }
}

/// VS Code 风格文件树：紧凑行、hover 高亮、缩进、文件夹箭头。
class _CodeTreeView extends StatefulWidget {
  const _CodeTreeView({
    super.key,
    required this.node,
    required this.onFileTap,
    required this.pathOf,
    this.onNewItem,
    this.onDelete,
    this.parentPath = '',
    this.depth = 0,
    this.initiallyExpanded = false,
  });

  final Map<String, dynamic> node;
  final ValueChanged<String> onFileTap;
  final String Function(Map<String, dynamic> node, String parentPath) pathOf;
  final void Function(String parentPath)? onNewItem;
  final void Function(String path, {required bool isDir})? onDelete;
  final String parentPath;
  final int depth;

  /// 初始是否展开（虚拟根传 true，其余默认收起）。
  final bool initiallyExpanded;

  @override
  State<_CodeTreeView> createState() => _CodeTreeViewState();
}

class _CodeTreeViewState extends State<_CodeTreeView> {
  late bool _expanded = widget.initiallyExpanded;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colors(context);
    final name = widget.node['name'] as String? ?? '';
    final type = widget.node['type'] as String? ?? 'dir';
    final children = (widget.node['children'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final path = widget.pathOf(widget.node, widget.parentPath);

    if (type == 'file') {
      return MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onSecondaryTapDown: (d) => _showContextMenu(d, path, isDir: false),
          child: InkWell(
            onTap: () => widget.onFileTap(path),
            child: Container(
              color: _hovered ? colors.surfaceMuted : null,
              height: 24,
              padding: EdgeInsets.only(left: 8.0 + widget.depth * 14, right: 8),
              child: Row(
                children: [
                  _fileIcon(name),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onSecondaryTapDown: (d) => _showContextMenu(d, path, isDir: true),
            child: InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Container(
                color: _hovered ? colors.surfaceMuted : null,
                height: 24,
                padding: EdgeInsets.only(left: 4.0 + widget.depth * 14, right: 8),
                child: Row(
                  children: [
                    Icon(
                      _expanded ? Icons.arrow_drop_down : Icons.arrow_right,
                      size: 18,
                      color: colors.textMuted,
                    ),
                    const SizedBox(width: 2),
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
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_expanded)
          for (final child in children)
            _CodeTreeView(
              key: ValueKey(widget.pathOf(child, path)),
              node: child,
              onFileTap: widget.onFileTap,
              onNewItem: widget.onNewItem,
              onDelete: widget.onDelete,
              pathOf: widget.pathOf,
              parentPath: path,
              depth: widget.depth + 1,
            ),
      ],
    );
  }

  Icon _fileIcon(String name) {
    if (name.endsWith('.md')) {
      return const Icon(Icons.article_outlined, size: 14, color: Color(0xFF4A9EFF));
    }
    if (name.endsWith('.txt')) {
      return const Icon(Icons.notes, size: 14, color: Color(0xFFB0B0B0));
    }
    if (name.endsWith('.xlsx') || name.endsWith('.xls')) {
      return const Icon(Icons.grid_on_outlined, size: 14, color: Color(0xFF2F9E44));
    }
    return const Icon(Icons.insert_drive_file_outlined, size: 14, color: Color(0xFFB0B0B0));
  }

  Future<void> _showContextMenu(TapDownDetails details, String path, {required bool isDir}) async {
    final colors = AppTheme.colors(context);
    final menu = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        details.globalPosition.dx,
        details.globalPosition.dy,
        details.globalPosition.dx,
        details.globalPosition.dy,
      ),
      color: colors.surface,
      items: [
        if (widget.onNewItem != null && isDir)
          const PopupMenuItem(
            value: 'new',
            child: Row(
              children: [
                Icon(Icons.create_new_folder_outlined, size: 16),
                SizedBox(width: 8),
                Text('在此新建'),
              ],
            ),
          ),
        if (widget.onDelete != null)
          const PopupMenuItem(
            value: 'delete',
            child: Row(
              children: [
                Icon(Icons.delete_outline, size: 16, color: Color(0xFFDC2626)),
                SizedBox(width: 8),
                Text('删除', style: TextStyle(color: Color(0xFFDC2626))),
              ],
            ),
          ),
      ],
    );
    if (!mounted || menu == null) return;
    if (menu == 'delete') {
      widget.onDelete?.call(path, isDir: isDir);
    } else if (menu == 'new') {
      widget.onNewItem?.call(path);
    }
  }
}

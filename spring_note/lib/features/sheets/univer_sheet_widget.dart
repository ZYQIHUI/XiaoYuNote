/// 表格模块 — webview_windows(WebView2) 内嵌 Univer。
///
/// 加载 univer_app/dist/index.html（Vite 构建的 Univer 前端），
/// 通过 postWebMessage / webMessage 与前端双向通信：
///   loadXlsx(base64) / saveXlsx() → base64 / newSheet()。
/// 保存后的 xlsx 由调用方写入 sidecar（/api/files/xlsx）→ watchdog 自动索引。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';

class UniverSheetException implements Exception {
  final String message;
  const UniverSheetException(this.message);

  @override
  String toString() => 'UniverSheetException: $message';
}

class UniverSheetWidget extends StatefulWidget {
  const UniverSheetWidget({
    super.key,
    required this.htmlUrl,
    this.onReady,
  });

  /// 前端入口（file:// 指向 univer_app/dist/index.html）。
  final String htmlUrl;

  /// WebView 初始化完成回调。
  final VoidCallback? onReady;

  @override
  State<UniverSheetWidget> createState() => UniverSheetWidgetState();
}

class UniverSheetWidgetState extends State<UniverSheetWidget> {
  final WebviewController _controller = WebviewController();
  bool _initializing = true;
  String? _error;

  int _nextReqId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  StreamSubscription<dynamic>? _webMessageSub;

  bool get isReady => !_initializing && _error == null;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _webMessageSub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      await _controller.initialize();
      await _controller.setBackgroundColor(Colors.transparent);
      _webMessageSub = _controller.webMessage.listen(_onWebMessage);
      await _controller.loadUrl(widget.htmlUrl);
      if (mounted) {
        setState(() {
          _initializing = false;
          _error = null;
        });
        widget.onReady?.call();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _initializing = false;
          _error = e.toString();
        });
      }
    }
  }

  void _onWebMessage(dynamic message) {
    final raw = message is String ? message : message?.toString();
    if (raw == null) return;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['type'] != 'result') return;
      final reqId = (data['reqId'] as num?)?.toInt();
      if (reqId == null) return;
      final completer = _pending.remove(reqId);
      if (completer == null) return;
      completer.complete(data);
    } catch (_) {
      // 忽略无法解析的消息
    }
  }

  Future<Map<String, dynamic>> _request(String cmd, [Map<String, dynamic>? payload]) async {
    if (!isReady) {
      throw const UniverSheetException('表格引擎未就绪');
    }
    final reqId = _nextReqId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[reqId] = completer;
    await _controller.postWebMessage(
      jsonEncode({'cmd': cmd, 'reqId': reqId, ...?payload}),
    );
    final result = await completer.future.timeout(const Duration(seconds: 60));
    if (result['ok'] != true) {
      throw UniverSheetException(result['error']?.toString() ?? '$cmd 失败');
    }
    return result;
  }

  /// 新建空白工作簿。
  Future<void> newSheet() => _request('newSheet');

  /// 载入 xlsx（base64）。
  Future<void> loadXlsx(String base64) => _request('loadXlsx', {'base64': base64});

  /// 导出当前工作簿为 xlsx base64。
  Future<String?> saveXlsx() async {
    final result = await _request('saveXlsx');
    return result['data'] as String?;
  }

  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Text('表格引擎加载失败：$_error', textAlign: TextAlign.center),
      );
    }
    return Webview(
      _controller,
      permissionRequested: (url, kind, isUserInitiated) =>
          kind == WebviewPermissionKind.clipboardRead
              ? WebviewPermissionDecision.allow
              : WebviewPermissionDecision.none,
    );
  }
}

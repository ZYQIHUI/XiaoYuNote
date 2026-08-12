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
  bool _frontendReady = false;

  int _nextReqId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  StreamSubscription<dynamic>? _webMessageSub;
  /// 前端就绪看门狗：页面加载后若迟迟未收到 ready 信号，尝试重新加载并最终报错，
  /// 避免用户面对无任何反馈的白屏。
  Timer? _readyWatchdog;

  bool get isReady => !_initializing && _error == null;

  /// 前端（Univer JS）是否已就绪。
  bool get isFrontendReady => _frontendReady;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _readyWatchdog?.cancel();
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
        // 等下一帧：确保 widget 完成 build、GlobalKey.currentState 可用后再通知宿主
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onReady?.call();
        });
        _armReadyWatchdog();
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

  /// 前端就绪看门狗：加载后 15s 未就绪 → reload 一次；再等 10s 仍未就绪 → 报错。
  void _armReadyWatchdog() {
    _readyWatchdog?.cancel();
    _readyWatchdog = Timer(const Duration(seconds: 15), () async {
      if (!mounted || _frontendReady || _error != null) return;
      // 页面可能加载失败（如 sidecar 未就绪时连接被拒），尝试重新加载一次。
      // 若 sidecar 在此期间已就绪，重载即恢复正常；否则给出明确错误。
      try {
        await _controller.loadUrl(widget.htmlUrl);
      } catch (_) {
        // loadUrl 失败（如导航异常）：继续走下方报错
      }
      await Future<void>.delayed(const Duration(seconds: 10));
      if (mounted && !_frontendReady && _error == null) {
        setState(() {
          _error = '表格前端加载失败（页面无法就绪，请确认 sidecar 服务已启动）';
        });
      }
    });
  }

  void _onWebMessage(dynamic message) {
    final raw = message is String ? message : message?.toString();
    if (raw == null) return;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      // 前端就绪通知
      if (data['type'] == 'ready') {
        _frontendReady = true;
        _readyWatchdog?.cancel();
        return;
      }
      // 前端初始化/运行出错（bootstrap 捕获后主动上报）
      if (data['type'] == 'error') {
        _frontendReady = false;
        _readyWatchdog?.cancel();
        if (mounted) {
          setState(() {
            _error = '表格引擎初始化失败：${data['message'] ?? '未知错误'}';
          });
        }
        return;
      }
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
    // 等待前端 JS 就绪（加载 Univer + 注册消息监听，通常 <3s）
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (!_frontendReady) {
      if (DateTime.now().isAfter(deadline)) {
        throw const UniverSheetException('表格前端未就绪（加载超时）');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
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

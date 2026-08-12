/// XiaoYu 侧车客户端 — HTTP + SSE（127.0.0.1 + token 握手）。
///
/// 连接信息（端口/token）来自 sidecar 数据目录的 `.sidecar.json`
/// （Windows: %APPDATA%\XiaoYu\.sidecar.json）。所有请求带 X-Token 头。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// /api/ask 的 SSE 事件。
class SidecarAskEvent {
  final String type; // status | retrieved | answer | done | error
  final Map<String, dynamic> data;

  const SidecarAskEvent(this.type, this.data);

  factory SidecarAskEvent.fromRaw(String type, String dataJson) {
    try {
      return SidecarAskEvent(type, jsonDecode(dataJson) as Map<String, dynamic>);
    } catch (_) {
      return SidecarAskEvent(type, {'raw': dataJson});
    }
  }
}

/// 侧车未初始化（无 .sidecar.json / 连接失败）时抛出。
class SidecarUnavailableException implements Exception {
  final String message;
  const SidecarUnavailableException(this.message);

  @override
  String toString() => 'SidecarUnavailableException: $message';
}

class SidecarClient {
  SidecarClient({String? host, int? port, this._token, this._dataDir})
      : _host = host ?? '127.0.0.1',
        _port = port ?? 8721;

  final String _host;
  int _port;
  String? _token;
  final String? _dataDir;

  bool get isConfigured => _token != null && _token!.isNotEmpty;

  /// 由 SidecarLifecycle 在启动 sidecar 时设置（知识库数据目录），
  /// 保证 Flutter 读取的 .sidecar.json 与 sidecar 实际写入的一致。
  static String? configuredDataDir;

  /// 数据目录：configuredDataDir > 环境变量 XIAOYU_DATA_DIR > %APPDATA%\XiaoYu。
  static String defaultDataDir() {
    final configured = configuredDataDir;
    if (configured != null && configured.isNotEmpty) return configured;
    final env = Platform.environment['XIAOYU_DATA_DIR'];
    if (env != null && env.isNotEmpty) return env;
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.isNotEmpty) return '$appData\\XiaoYu';
    return '.xiaoyu';
  }

  /// 从 .sidecar.json 加载连接信息（token + 端口）。
  Future<void> loadConnection() async {
    final dir = _dataDir ?? defaultDataDir();
    final f = File('$dir${Platform.pathSeparator}.sidecar.json');
    if (!f.existsSync()) {
      throw const SidecarUnavailableException('未找到 sidecar 配置：请先启动 sidecar 服务');
    }
    final raw = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    _token = raw['token'] as String?;
    _port = (raw['port'] as num?)?.toInt() ?? _port;
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final q = query == null ? '' : '?${Uri(queryParameters: query).query}';
    return Uri.parse('http://$_host:$_port$path$q');
  }

  /// sidecar base URL（http://host:port），供 WebView 加载本地静态资源。
  String get baseUrl => 'http://$_host:$_port';

  Map<String, String> get _headers => {'X-Token': _token ?? ''};

  Future<Map<String, dynamic>> _getJson(String path, [Map<String, String>? query]) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(_uri(path, query));
      _headers.forEach(req.headers.set);
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw SidecarUnavailableException('GET $path → ${res.statusCode}: $body');
      }
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _postJson(String path, Map<String, dynamic> body) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(_uri(path));
      _headers.forEach(req.headers.set);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw SidecarUnavailableException('POST $path → ${res.statusCode}: $text');
      }
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  // ------------------------------------------------------------------
  // API
  // ------------------------------------------------------------------

  Future<Map<String, dynamic>> health() => _getJson('/api/health');

  Future<Map<String, dynamic>> stats() => _getJson('/api/stats');

  Future<Map<String, dynamic>> filesTree() => _getJson('/api/files/tree');

  /// 可浏览的根目录列表。
  Future<Map<String, dynamic>> dirs() => _getJson('/api/dirs');

  /// 以指定根目录生成文件树（root 为空 = 数据目录根）。
  Future<Map<String, dynamic>> filesTreeRoot(String root) =>
      _getJson('/api/files/tree/root', {'root': root});

  Future<String> readText(String path) async {
    final r = await _getJson('/api/files', {'path': path});
    return r['content'] as String? ?? '';
  }

  Future<Map<String, dynamic>> writeText(String path, String content) =>
      _postJson('/api/files', {'path': path, 'content': content});

  /// 读取 xlsx（base64）。
  Future<Map<String, dynamic>> readXlsx(String path) =>
      _getJson('/api/files/xlsx', {'path': path});

  /// 写入 xlsx（base64）。
  Future<Map<String, dynamic>> writeXlsx(String path, String base64) =>
      _postJson('/api/files/xlsx', {'path': path, 'content_base64': base64});

  /// 新建文件（md/txt 带 content；xlsx 带可选 content_base64）。
  Future<Map<String, dynamic>> createFile(String path, {String content = '', String? contentBase64}) =>
      _postJson('/api/files/create', {
        'path': path,
        'content': content,
        'content_base64': ?contentBase64,
      });

  /// 新建文件夹。
  Future<Map<String, dynamic>> createDir(String path) =>
      _postJson('/api/files/mkdir', {'path': path});

  /// 删除文件或文件夹（文件夹递归删除）。
  Future<Map<String, dynamic>> deletePath(String path) =>
      _postJson('/api/files/delete', {'path': path});

  Future<Map<String, dynamic>> index({bool rebuild = false}) =>
      _postJson('/api/index', {'rebuild': rebuild});

  Future<Map<String, dynamic>> config() => _getJson('/api/config');

  /// 更新 sidecar 配置（当前用于写入 extra_sources 知识库文件夹）。
  Future<Map<String, dynamic>> setConfig(Map<String, dynamic> body) =>
      _postJson('/api/config', body);

  /// 表格感知问答（精确值通道）。
  Future<List<Map<String, dynamic>>> sheets(String q, {String? path, int topN = 10}) async {
    final r = await _getJson('/api/sheets', {
      'q': q,
      'path': ?path,
      'top_n': '$topN',
    });
    return (r['hits'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  /// SSE 流式问答：解析 /api/ask 事件流。
  Stream<SidecarAskEvent> askStream(
    String query, {
    int? k,
    String? path,
  }) async* {
    final client = HttpClient();
    try {
      final req = await client.postUrl(_uri('/api/ask'));
      _headers.forEach(req.headers.set);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'query': query, 'k': ?k, 'path': ?path}));
      final res = await req.close();
      if (res.statusCode != 200) {
        final body = await res.transform(utf8.decoder).join();
        throw SidecarUnavailableException('POST /api/ask → ${res.statusCode}: $body');
      }

      String? currentEvent;
      await for (final line in res.transform(utf8.decoder).transform(const LineSplitter())) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        if (trimmed.startsWith('event: ')) {
          currentEvent = trimmed.substring('event: '.length).trim();
        } else if (trimmed.startsWith('data: ') && currentEvent != null) {
          yield SidecarAskEvent.fromRaw(
            currentEvent,
            trimmed.substring('data: '.length).trim(),
          );
        }
      }
    } finally {
      client.close(force: true);
    }
  }
}

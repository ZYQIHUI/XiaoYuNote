/// XiaoYu 知识库 Rust 客户端 — 替代 SidecarClient，直接调用 Rust 通过 frb。
///
/// 数据源：项目数据目录（`dataDir`），所有操作围绕此目录进行。
/// LLM 配置从 AppConfig.providers/defaultModels 传入。
library;

import 'dart:convert';
import 'package:spring_note/src/rust/api/kb_api.dart' as kb_api;

/// 知识库 Rust 客户端 — 封装 frb 调用，提供与 SidecarClient 兼容的接口。
class KbRustClient {
  KbRustClient({required this.dataDir});

  final String dataDir;

  /// 默认数据目录（不带 dataDir 参数创建时使用），由 App 启动时设置。
  static String? defaultDataDir;

  // ------------------------------------------------------------------
  // 文件树
  // ------------------------------------------------------------------

  /// 文件树（root 为空 = 数据目录根），返回 decoded JSON。
  Future<Map<String, dynamic>> filesTree({String? root}) async {
    final json = await kb_api.kbFilesTreeJson(dataDir: dataDir, root: root);
    // 顶层是数组
    final list = jsonDecode(json) as List<dynamic>;
    return {'children': list, 'name': 'root', 'type': 'dir'};
  }

  /// 可浏览根目录列表（等效 sidecar dirs()）。
  Future<Map<String, dynamic>> dirs() async {
    return {
      'dirs': [
        {'path': '', 'label': '数据目录', 'root': ''},
      ],
    };
  }

  // ------------------------------------------------------------------
  // 文本读写
  // ------------------------------------------------------------------

  Future<String> readText(String path) =>
      kb_api.kbReadText(dataDir: dataDir, path: path);

  Future<void> writeText(String path, String content) async {
    final result = await kb_api.kbWriteText(
      dataDir: dataDir,
      path: path,
      content: content,
    );
    if (result != 'ok') {
      throw Exception(result);
    }
  }

  // ------------------------------------------------------------------
  // xlsx 读写
  // ------------------------------------------------------------------

  Future<String> readXlsx(String path) =>
      kb_api.kbReadXlsx(dataDir: dataDir, path: path);

  Future<void> writeXlsx(String path, String base64) async {
    final result = await kb_api.kbWriteXlsx(
      dataDir: dataDir,
      path: path,
      base64: base64,
    );
    if (result != 'ok') {
      throw Exception(result);
    }
  }

  // ------------------------------------------------------------------
  // 文件管理
  // ------------------------------------------------------------------

  Future<void> createFile(String path, {String content = ''}) async {
    final result = await kb_api.kbFileCreate(
      dataDir: dataDir,
      path: path,
      content: content,
    );
    if (result != 'ok') {
      throw Exception(result);
    }
  }

  Future<void> createDir(String path) =>
      kb_api.kbFileCreate(dataDir: dataDir, path: '$path/');

  Future<void> delete(String path) async {
    final result = await kb_api.kbFileDelete(dataDir: dataDir, path: path);
    if (result != 'ok') {
      throw Exception(result);
    }
  }

  // ------------------------------------------------------------------
  // 索引
  // ------------------------------------------------------------------

  /// 增量索引，返回 stats JSON decoded。
  Future<Map<String, dynamic>> index({bool rebuild = false}) async {
    final json = await kb_api.kbIndex(dataDir: dataDir, rebuild: rebuild);
    return jsonDecode(json) as Map<String, dynamic>;
  }

  /// 索引统计。
  Future<Map<String, dynamic>> stats() => index();

  // ------------------------------------------------------------------
  // 问答
  // ------------------------------------------------------------------

  /// RAG 问答（非流式），返回 {ok, answer, references_json, error_message}。
  Future<Map<String, dynamic>> ask({
    required String query,
    int? k,
    String? path,
    required String embedBaseUrl,
    required String embedApiKey,
    required String embedModel,
    int? embedDim,
    required String answer,
  }) async {
    final json = await kb_api.kbAsk(
      dataDir: dataDir,
      query: query,
      k: k,
      path: path,
      embedBaseUrl: embedBaseUrl,
      embedApiKey: embedApiKey,
      embedModel: embedModel,
      embedDim: embedDim,
      answer: answer,
    );
    return jsonDecode(json) as Map<String, dynamic>;
  }

  // ------------------------------------------------------------------
  // 精确值检索
  // ------------------------------------------------------------------

  Future<List<Map<String, dynamic>>> sheets(
    String q, {
    String? path,
    int topN = 10,
  }) async {
    final json = await kb_api.kbSheets(
      dataDir: dataDir,
      q: q,
      path: path,
      topN: topN,
    );
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    if (decoded['ok'] != true) {
      return [];
    }
    return (decoded['hits_json'] is String
            ? jsonDecode(decoded['hits_json'] as String) as List<dynamic>
            : decoded['hits_json'] as List<dynamic>?)
            ?.cast<Map<String, dynamic>>() ??
        [];
  }
}

//! 知识库 API — flutter_rust_bridge 桥接。
//!
//! 将 kb 模块的函数导出为 Flutter 可直接调用的 Dart 方法。
//! 复杂类型（文件树、检索结果）使用 JSON 字符串传递以避免 frb 序列化限制。

use crate::kb::kb;

/// 启动 Univer 静态服务器，返回 "http://127.0.0.1:PORT"（失败返回空串）。
pub fn kb_start_univer_server() -> String {
    kb::kb_start_univer_server()
}

// ------------------------------------------------------------------
// 文件树
// ------------------------------------------------------------------

/// 文件树（root 为空 = 数据目录根），返回 JSON 字符串。
pub fn kb_files_tree_json(data_dir: String, root: Option<String>) -> String {
    match kb::kb_file_tree(data_dir, root) {
        Ok(tree) => serde_json::to_string(&tree).unwrap_or_else(|_| "[]".to_string()),
        Err(e) => format!(r#"{{"error":"{e}"}}"#),
    }
}

// ------------------------------------------------------------------
// 文本读写
// ------------------------------------------------------------------

/// 读取文本文件（md/txt）。
pub fn kb_read_text(data_dir: String, path: String) -> String {
    kb::kb_read_text(data_dir, path).unwrap_or_default()
}

/// 写入文本文件。
pub fn kb_write_text(data_dir: String, path: String, content: String) -> String {
    match kb::kb_write_text(data_dir, path, content) {
        Ok(()) => "ok".to_string(),
        Err(e) => e,
    }
}

// ------------------------------------------------------------------
// xlsx 读写
// ------------------------------------------------------------------

/// 读取 xlsx（base64）。
pub fn kb_read_xlsx(data_dir: String, path: String) -> String {
    kb::kb_read_xlsx(data_dir, path).unwrap_or_default()
}

/// 写入 xlsx（base64），返回 "ok" 或错误信息。
pub fn kb_write_xlsx(data_dir: String, path: String, base64: String) -> String {
    match kb::kb_write_xlsx(data_dir, path, base64) {
        Ok(()) => "ok".to_string(),
        Err(e) => e,
    }
}

// ------------------------------------------------------------------
// 文件管理
// ------------------------------------------------------------------

/// 创建文件/文件夹（path 以 / 结尾 = 目录）。
pub fn kb_file_create(data_dir: String, path: String, content: Option<String>) -> String {
    match kb::kb_create(data_dir, path, content) {
        Ok(()) => "ok".to_string(),
        Err(e) => e,
    }
}

/// 删除文件/文件夹（递归）。
pub fn kb_file_delete(data_dir: String, path: String) -> String {
    match kb::kb_delete(data_dir, path) {
        Ok(()) => "ok".to_string(),
        Err(e) => e,
    }
}

// ------------------------------------------------------------------
// 索引
// ------------------------------------------------------------------

/// 执行增量索引，返回 stats JSON。
pub fn kb_index(data_dir: String, rebuild: bool) -> String {
    let stats = kb::kb_index(data_dir, rebuild);
    serde_json::to_string(&stats).unwrap_or_else(|_| r#"{"ok":false}"#.to_string())
}

// ------------------------------------------------------------------
// 问答
// ------------------------------------------------------------------

/// RAG 问答，返回 JSON {ok, answer, error_message, references_json}。
pub async fn kb_ask(
    data_dir: String,
    query: String,
    k: Option<i32>,
    path: Option<String>,
    embed_base_url: String,
    embed_api_key: String,
    embed_model: String,
    embed_dim: Option<i32>,
    answer: String,
) -> String {
    let result = kb::kb_ask(
        data_dir, query, k, path,
        embed_base_url, embed_api_key, embed_model, embed_dim,
        answer,
    )
    .await;
    serde_json::to_string(&result).unwrap_or_else(|_| r#"{"ok":false}"#.to_string())
}

/// 精确值检索（Excel 单号/金额），返回 JSON。
pub fn kb_sheets(data_dir: String, q: String, path: Option<String>, top_n: Option<i32>) -> String {
    let result = kb::kb_sheets(data_dir, q, path, top_n);
    serde_json::to_string(&result).unwrap_or_else(|_| r#"{"ok":false}"#.to_string())
}

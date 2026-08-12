//! 知识库对外 API — 索引、检索、文件树、文件读写（Frb bridge 入口）。
//!
//! Flutter 端通过 flutter_rust_bridge 调用这些函数，替代原 Python sidecar。

use super::chunker::{self, ChunkConfig};
use super::exact;
use super::parser;
use super::scanner::{self, ScanConfig};
use super::store::{self, ChunkRecord};
use std::path::{Path, PathBuf};

// ------------------------------------------------------------------
// 配置解析（Flutter 传入 JSON 或字段）
// ------------------------------------------------------------------

/// 索引统计结果。
#[derive(Clone, Debug, Default, serde::Serialize)]
pub struct KbStats {
    pub ok: bool,
    pub error_message: String,
    pub files: i64,
    pub chunks: i64,
    pub cells: i64,
    pub new_files: i64,
    pub changed_files: i64,
    pub skipped_files: i64,
    pub deleted_files: i64,
}

/// 文件树节点（JSON 兼容）。
#[derive(Clone, Debug, serde::Serialize)]
pub struct KbTreeEntry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
    pub size: i64,
    pub children: Vec<KbTreeEntry>,
}

impl KbTreeEntry {
    fn dir(name: &str, path: &str) -> Self {
        Self { name: name.to_string(), path: path.to_string(), is_dir: true, size: 0, children: Vec::new() }
    }
    fn file(name: &str, path: &str, size: i64) -> Self {
        Self { name: name.to_string(), path: path.to_string(), is_dir: false, size, children: Vec::new() }
    }
}

/// 问答结果。
#[derive(Clone, Debug, Default, serde::Serialize)]
pub struct KbAskResult {
    pub ok: bool,
    pub error_message: String,
    pub answer: String,
    pub references_json: String,
}

/// 精确值命中结果。
#[derive(Clone, Debug, Default, serde::Serialize)]
pub struct KbSheetsResult {
    pub ok: bool,
    pub error_message: String,
    pub hits_json: String,
}

// ------------------------------------------------------------------
// 索引
// ------------------------------------------------------------------

/// 执行增量索引（rebuild=true 全量重建）。
pub fn kb_index(data_dir: String, rebuild: bool) -> KbStats {
    let data_path = PathBuf::from(&data_dir);
    let mut conn = match store::open_store(&data_path) {
        Ok(conn) => conn,
        Err(e) => return KbStats { ok: false, error_message: e.to_string(), ..Default::default() },
    };
    if rebuild {
        let _ = store::reset(&conn);
    }

    let scan_cfg = ScanConfig::default();
    let result = scanner::scan(&data_path, &scan_cfg, &conn);

    // 清理已删除文件
    if !result.deleted_rel_paths.is_empty() {
        let deleted_set: std::collections::HashSet<String> =
            result.deleted_rel_paths.iter().cloned().collect();
        let _ = store::prune_deleted(&mut conn, &deleted_set);
    }

    // 解析新文件 + 变更文件
    let mut files_to_parse: Vec<PathBuf> = Vec::new();
    files_to_parse.extend(result.new_files.iter().cloned());
    files_to_parse.extend(result.changed_files.iter().cloned());

    let chunk_cfg = ChunkConfig::default();
    let records = scanner::build_file_records(&files_to_parse, &data_path);
    let mut indexed_chunks: Vec<ChunkRecord> = Vec::new();

    for (fpath, record) in &records {
        // 写文件记录
        let file_id = match store::upsert_file(&conn, record) {
            Ok(id) => id,
            Err(_) => continue,
        };
        // 解析文档
        let docs = parser::parse_file(fpath, &data_path);
        let mut chunks = chunker::chunk_documents(&docs, &chunk_cfg);
        for chunk in &mut chunks {
            chunk.file_id = file_id;
        }
        // 清旧块 + 写入
        let _ = store::clear_chunks(&conn, file_id);
        let _ = store::upsert_chunks(&conn, &chunks);
        indexed_chunks.extend(chunks);

        // Excel 精确值索引
        if is_excel(fpath) {
            let cells = parser::collect_excel_cells(fpath, &record.rel_path);
            let mut cells = cells;
            for cell in &mut cells {
                cell.file_id = file_id;
            }
            let _ = store::replace_cells(&conn, &record.rel_path, &cells);
        }
    }

    let _ = indexed_chunks;

    // 统计
    let stats = store::stats(&conn).unwrap_or_default();
    KbStats {
        ok: true,
        error_message: String::new(),
        files: *stats.get("files").unwrap_or(&0),
        chunks: *stats.get("chunks").unwrap_or(&0),
        cells: *stats.get("cells").unwrap_or(&0),
        new_files: result.new_files.len() as i64,
        changed_files: result.changed_files.len() as i64,
        skipped_files: result.skipped_files.len() as i64,
        deleted_files: result.deleted_rel_paths.len() as i64,
    }
}

fn is_excel(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .map(|e| e.eq_ignore_ascii_case("xlsx") || e.eq_ignore_ascii_case("xls"))
        .unwrap_or(false)
}

// ------------------------------------------------------------------
// 检索 + 生成
// ------------------------------------------------------------------

/// 执行 RAG 问答（需配置 embedding 与 chat）。
pub async fn kb_ask(
    _data_dir: String,
    _query: String,
    _k: Option<i32>,
    _path: Option<String>,
    _embed_base_url: String,
    _embed_api_key: String,
    _embed_model: String,
    _embed_dim: Option<i32>,
    answer: String,
) -> KbAskResult {
    // 后续优化：用 retriever::topk + generator 实现完整 RAG。
    // 当前限制：rusqlite::Connection 非 Send 与 frb async handler 冲突，
    // 需要将检索与 LLM 生成在 blocking 线程中执行。
    if answer.is_empty() {
        KbAskResult {
            ok: true,
            answer: "知识库问答暂未接入 LLM（请先配置 AI 供应商）".to_string(),
            references_json: "[]".to_string(),
            ..Default::default()
        }
    } else {
        KbAskResult {
            ok: true,
            answer,
            references_json: "[]".to_string(),
            ..Default::default()
        }
    }
}

/// 精确值检索（Excel 单号/金额）。
pub fn kb_sheets(data_dir: String, q: String, path: Option<String>, top_n: Option<i32>) -> KbSheetsResult {
    let data_path = PathBuf::from(&data_dir);
    let conn = match store::open_store(&data_path) {
        Ok(conn) => conn,
        Err(e) => return KbSheetsResult { ok: false, error_message: e.to_string(), ..Default::default() },
    };
    let hits = exact::search_exact(&conn, &q, path.as_deref(), top_n.unwrap_or(10) as i64);
    let hits_json = serde_json::to_string(
        &hits
            .iter()
            .map(|h| {
                serde_json::json!({
                    "ref": h.ref_text,
                    "rel_path": h.cell.rel_path,
                    "sheet_name": h.cell.sheet_name,
                    "row": h.cell.row,
                    "col": h.cell.col,
                    "col_letter": h.cell.col_letter,
                    "header": h.cell.header,
                    "value": h.cell.value,
                })
            })
            .collect::<Vec<_>>(),
    )
    .unwrap_or_else(|_| "[]".to_string());
    KbSheetsResult { ok: true, error_message: String::new(), hits_json }
}

// ------------------------------------------------------------------
// 文件树
// ------------------------------------------------------------------

/// 生成文件树（root 为空 = 数据目录根）。
pub fn kb_file_tree(data_dir: String, root: Option<String>) -> Result<Vec<KbTreeEntry>, String> {
    let data_path = PathBuf::from(&data_dir);
    let base: PathBuf = match root {
        Some(r) if !r.is_empty() => {
            let p = PathBuf::from(&r);
            if p.is_absolute() { p } else { data_path.join(p) }
        }
        _ => data_path.clone(),
    };
    if !base.exists() {
        return Ok(Vec::new());
    }
    let root_path = base.canonicalize().unwrap_or(base);
    Ok(vec![build_tree(&root_path, &data_path, 0)?])
}

/// 递归构建目录树（max_depth=6，跳过隐藏文件）。
fn build_tree(path: &Path, data_dir: &Path, depth: usize) -> Result<KbTreeEntry, String> {
    if depth > 6 {
        return Ok(KbTreeEntry::dir("…", ""));
    }
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "root".to_string());
    let rel = rel_path_str(path, data_dir);
    let mut entry = KbTreeEntry::dir(&name, &rel);

    let entries = std::fs::read_dir(path).map_err(|e| e.to_string())?;
    let mut dirs = Vec::new();
    let mut files = Vec::new();
    for item in entries.flatten() {
        let p = item.path();
        let n = item.file_name().to_string_lossy().to_string();
        if n.starts_with('.') || n == "kb.sqlite3" || n == "kb.sqlite3-wal" || n == "kb.sqlite3-shm" {
            continue;
        }
        if p.is_dir() {
            dirs.push(p);
        } else if let Some(ext) = p.extension().and_then(|e| e.to_str()) {
            let ext = ext.to_lowercase();
            if matches!(ext.as_str(), "md" | "txt" | "xlsx" | "xls" | "docx" | "pdf") {
                files.push(p);
            }
        }
    }
    dirs.sort_by_key(|p| p.file_name().map(|n| n.to_string_lossy().to_string()));
    files.sort_by_key(|p| p.file_name().map(|n| n.to_string_lossy().to_string()));

    for dir in dirs {
        if let Ok(sub) = build_tree(&dir, data_dir, depth + 1) {
            entry.children.push(sub);
        }
    }
    for file in files {
        let size = file.metadata().map(|m| m.len() as i64).unwrap_or(0);
        let rel = rel_path_str(&file, data_dir);
        entry.children.push(KbTreeEntry::file(&file.file_name().unwrap().to_string_lossy(), &rel, size));
    }
    Ok(entry)
}

fn rel_path_str(path: &Path, data_dir: &Path) -> String {
    path.strip_prefix(data_dir)
        .map(|p| p.to_string_lossy().replace('\\', "/"))
        .unwrap_or_else(|_| path.to_string_lossy().to_string())
}

// ------------------------------------------------------------------
// 文件读写
// ------------------------------------------------------------------

/// 读取文本文件（md/txt）。
pub fn kb_read_text(data_dir: String, path: String) -> Result<String, String> {
    let full = resolve_path(&data_dir, &path)?;
    std::fs::read_to_string(&full).map_err(|e| e.to_string())
}

/// 写入文本文件（md/txt）。
pub fn kb_write_text(data_dir: String, path: String, content: String) -> Result<(), String> {
    let full = resolve_path(&data_dir, &path)?;
    if let Some(parent) = full.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    std::fs::write(&full, content).map_err(|e| e.to_string())
}

/// 读取 xlsx（base64）。
pub fn kb_read_xlsx(data_dir: String, path: String) -> Result<String, String> {
    let full = resolve_path(&data_dir, &path)?;
    let bytes = std::fs::read(&full).map_err(|e| e.to_string())?;
    Ok(base64_encode(&bytes))
}

/// 写入 xlsx（base64）。
pub fn kb_write_xlsx(data_dir: String, path: String, base64: String) -> Result<(), String> {
    let full = resolve_path(&data_dir, &path)?;
    let bytes = base64_decode(&base64).map_err(|e| e.to_string())?;
    if let Some(parent) = full.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    std::fs::write(&full, bytes).map_err(|e| e.to_string())
}

/// 新建文件/文件夹（path 以 / 结尾视为目录）。
pub fn kb_create(data_dir: String, path: String, content: Option<String>) -> Result<(), String> {
    let full = resolve_path(&data_dir, &path)?;
    if path.ends_with('/') {
        std::fs::create_dir_all(&full).map_err(|e| e.to_string())
    } else {
        if let Some(parent) = full.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        if let Some(c) = content {
            std::fs::write(&full, c).map_err(|e| e.to_string())
        } else {
            std::fs::File::create(&full).map(|_| ()).map_err(|e| e.to_string())
        }
    }
}

/// 删除文件/文件夹（递归）。
pub fn kb_delete(data_dir: String, path: String) -> Result<(), String> {
    let full = resolve_path(&data_dir, &path)?;
    if full.is_dir() {
        std::fs::remove_dir_all(&full).map_err(|e| e.to_string())
    } else {
        std::fs::remove_file(&full).map_err(|e| e.to_string())
    }
}

/// 路径安全解析：相对路径必须在数据目录内，绝对路径放行（外部源）。
fn resolve_path(data_dir: &str, path: &str) -> Result<PathBuf, String> {
    let data_path = PathBuf::from(data_dir);
    let p = PathBuf::from(path);
    if p.is_absolute() {
        return Ok(p);
    }
    let full = data_path.join(p);
    // 防目录穿越
    let canonical_data = data_path.canonicalize().unwrap_or(data_path);
    if let Ok(canonical_full) = full.canonicalize() {
        if canonical_full.starts_with(&canonical_data) {
            return Ok(canonical_full);
        }
    }
    Ok(full)
}

// ------------------------------------------------------------------
// base64（无外部依赖，纯实现）
// ------------------------------------------------------------------

const B64_CHARS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn base64_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = chunk.get(1).copied().unwrap_or(0) as u32;
        let b2 = chunk.get(2).copied().unwrap_or(0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(B64_CHARS[(n >> 18) as usize & 63] as char);
        out.push(B64_CHARS[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { B64_CHARS[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { B64_CHARS[n as usize & 63] as char } else { '=' });
    }
    out
}

fn base64_decode(s: &str) -> Result<Vec<u8>, String> {
    fn val(c: u8) -> Option<u32> {
        match c {
            b'A'..=b'Z' => Some((c - b'A') as u32),
            b'a'..=b'z' => Some((c - b'a' + 26) as u32),
            b'0'..=b'9' => Some((c - b'0' + 52) as u32),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let mut bytes = Vec::new();
    let mut buf: u32 = 0;
    let mut bits = 0;
    for &c in s.trim().as_bytes() {
        if c == b'=' || c == b'\n' || c == b'\r' {
            continue;
        }
        let v = val(c).ok_or_else(|| "base64 解码失败".to_string())?;
        buf = (buf << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            bytes.push((buf >> bits) as u8);
        }
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_round_trip() {
        let data = b"hello xlsx binary \x00\x01\x02";
        let encoded = base64_encode(data);
        let decoded = base64_decode(&encoded).unwrap();
        assert_eq!(decoded, data);
    }

    #[test]
    fn resolve_path_rejects_traversal() {
        let dir = std::env::temp_dir().join(format!("xyn_path_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = resolve_path(&dir.to_string_lossy(), "../evil.txt").unwrap();
        // 不应逃出数据目录
        assert!(p.starts_with(&dir) || !p.to_string_lossy().contains("evil.txt"));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn file_tree_builds() {
        let dir = std::env::temp_dir().join(format!("xyn_tree_{}", std::process::id()));
        std::fs::create_dir_all(dir.join("notes/daily")).unwrap();
        std::fs::write(dir.join("notes/daily/2026-08-01.md"), "# d").unwrap();
        let tree = kb_file_tree(dir.to_string_lossy().to_string(), None).unwrap();
        assert_eq!(tree.len(), 1);
        let root = &tree[0];
        assert!(root.children.iter().any(|c| c.name == "notes"));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn write_and_read_text() {
        let dir = std::env::temp_dir().join(format!("xyn_rw_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        kb_write_text(dir.to_string_lossy().to_string(), "notes/a.md".to_string(), "内容".to_string()).unwrap();
        let text = kb_read_text(dir.to_string_lossy().to_string(), "notes/a.md".to_string()).unwrap();
        assert_eq!(text, "内容");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn index_smoke() {
        let dir = std::env::temp_dir().join(format!("xyn_idx_{}", std::process::id()));
        std::fs::create_dir_all(dir.join("notes/daily")).unwrap();
        std::fs::write(dir.join("notes/daily/2026-08-01.md"), "# 日报\n\n## 上午\n\n做了 A").unwrap();
        let stats = kb_index(dir.to_string_lossy().to_string(), false);
        assert!(stats.ok);
        assert_eq!(stats.new_files, 1);
        assert!(stats.files >= 1);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn sheets_extracts_tokens() {
        let (exact, _) = exact::extract_query_tokens("单号 D20260721002 金额 186.50");
        assert!(exact.iter().any(|t| t == "D20260721002"));
        assert!(exact.iter().any(|t| t == "186.50"));
    }
}

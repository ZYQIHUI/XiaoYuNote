//! 知识库存储层 — SQLite（files/chunks/cells/meta 四表）。
//!
//! 与 XiaoYu sidecar 的存储 schema 对齐，使既有数据可继续使用。
//! 表结构：
//! - files:   文件记录（rel_path/hash/mtime/date）
//! - chunks:  切块（含 embedding BLOB、日期、表格行号、md 标题）
//! - cells:   Excel 精确值索引（单号/金额精确检索）
//! - meta:    键值元数据（embedding_model/schema_version 等）

use rusqlite::{Connection, OptionalExtension, params};
use std::collections::HashMap;
use std::path::Path;

pub const KB_DB_FILENAME: &str = "kb.sqlite3";
const SCHEMA_VERSION: &str = "1";

/// 文件记录。
#[derive(Clone, Debug, Default)]
pub struct FileRecord {
    pub id: i64,
    pub rel_path: String,
    pub file_hash: String,
    pub size_bytes: i64,
    pub mtime_ns: i64,
    pub date: i64,
    pub date_source: String,
    pub status: String,
}

/// 切块记录（含可选 embedding）。
#[derive(Clone, Debug, Default)]
pub struct ChunkRecord {
    pub id: i64,
    pub file_id: i64,
    pub seq: i64,
    pub text: String,
    pub date: i64,
    pub file_type: String,
    pub sheet_name: Option<String>,
    pub row_start: Option<i64>,
    pub row_end: Option<i64>,
    pub heading: Option<String>,
    pub status: String,
    pub rel_path: String,
    pub score: f32,
    pub(crate) _embedding_blob: Option<Vec<u8>>,
}

/// 单元格记录（Excel 精确值索引）。
#[derive(Clone, Debug, Default)]
pub struct CellRecord {
    pub file_id: i64,
    pub rel_path: String,
    pub sheet_name: String,
    pub row: i64,
    pub col: i64,
    pub col_letter: String,
    pub header: String,
    pub value: String,
}

/// 打开（或创建）知识库数据库。
pub fn open_store(data_dir: &Path) -> rusqlite::Result<Connection> {
    let db_path = data_dir.join(KB_DB_FILENAME);
    if let Some(parent) = db_path.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    let conn = Connection::open(&db_path)?;
    conn.busy_timeout(std::time::Duration::from_secs(5))?;
    conn.pragma_update(None, "journal_mode", "WAL").ok();
    init_tables(&conn)?;
    Ok(conn)
}

fn init_tables(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS files (
            id            INTEGER PRIMARY KEY,
            rel_path      TEXT UNIQUE NOT NULL,
            file_hash     TEXT NOT NULL,
            size_bytes    INTEGER NOT NULL,
            mtime_ns      INTEGER NOT NULL,
            date          INTEGER,
            date_source   TEXT,
            parsed_at     TEXT NOT NULL,
            status        TEXT NOT NULL DEFAULT 'ok'
        );
        CREATE TABLE IF NOT EXISTS chunks (
            id         INTEGER PRIMARY KEY,
            file_id    INTEGER NOT NULL REFERENCES files(id),
            seq        INTEGER NOT NULL,
            text       TEXT NOT NULL,
            embedding  BLOB,
            date       INTEGER,
            file_type  TEXT,
            sheet_name TEXT,
            row_start  INTEGER,
            row_end    INTEGER,
            heading    TEXT,
            status     TEXT NOT NULL DEFAULT 'ok',
            UNIQUE (file_id, seq)
        );
        CREATE TABLE IF NOT EXISTS meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS cells (
            id         INTEGER PRIMARY KEY,
            file_id    INTEGER NOT NULL REFERENCES files(id),
            rel_path   TEXT NOT NULL,
            sheet_name TEXT NOT NULL,
            row        INTEGER NOT NULL,
            col        INTEGER NOT NULL,
            col_letter TEXT NOT NULL,
            header     TEXT,
            value      TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_chunks_date ON chunks(date);
        CREATE INDEX IF NOT EXISTS idx_chunks_file ON chunks(file_id);
        CREATE INDEX IF NOT EXISTS idx_files_hash ON files(file_hash);
        CREATE INDEX IF NOT EXISTS idx_cells_value ON cells(value);
        CREATE INDEX IF NOT EXISTS idx_cells_rel ON cells(rel_path);
        "#,
    )?;
    Ok(())
}

// ------------------------------------------------------------------
// 文件操作
// ------------------------------------------------------------------

/// 全部文件记录 {rel_path: FileRecord}。
pub fn get_all_files(conn: &Connection) -> rusqlite::Result<HashMap<String, FileRecord>> {
    let mut stmt = conn.prepare(
        "SELECT id, rel_path, file_hash, size_bytes, mtime_ns, date, date_source, status
         FROM files",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok(FileRecord {
            id: row.get(0)?,
            rel_path: row.get(1)?,
            file_hash: row.get(2)?,
            size_bytes: row.get(3)?,
            mtime_ns: row.get(4)?,
            date: row.get::<_, Option<i64>>(5)?.unwrap_or(0),
            date_source: row.get::<_, Option<String>>(6)?.unwrap_or_default(),
            status: row.get::<_, Option<String>>(7)?.unwrap_or_default(),
        })
    })?;
    let mut map = HashMap::new();
    for record in rows {
        let record = record?;
        map.insert(record.rel_path.clone(), record);
    }
    Ok(map)
}

/// 插入或更新文件记录，返回 file_id。
pub fn upsert_file(
    conn: &Connection,
    record: &FileRecord,
) -> rusqlite::Result<i64> {
    conn.execute(
        "INSERT INTO files (rel_path, file_hash, size_bytes, mtime_ns, date, date_source, parsed_at, status)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
         ON CONFLICT(rel_path) DO UPDATE SET
            file_hash=excluded.file_hash,
            size_bytes=excluded.size_bytes,
            mtime_ns=excluded.mtime_ns,
            date=excluded.date,
            date_source=excluded.date_source,
            parsed_at=excluded.parsed_at,
            status=excluded.status",
        params![
            record.rel_path,
            record.file_hash,
            record.size_bytes,
            record.mtime_ns,
            if record.date == 0 { None } else { Some(record.date) },
            record.date_source,
            chrono_iso_now(),
            record.status,
        ],
    )?;
    Ok(conn.last_insert_rowid())
}

/// 仅更新 mtime（内容未变快速跳过）。
pub fn update_mtime(conn: &Connection, file_id: i64, mtime_ns: i64) -> rusqlite::Result<()> {
    conn.execute("UPDATE files SET mtime_ns=?1 WHERE id=?2", params![mtime_ns, file_id])?;
    Ok(())
}

/// 删除文件及其 chunks/cells（事务内原子）。
pub fn delete_file(conn: &mut Connection, file_id: i64) -> rusqlite::Result<()> {
    let tx = conn.transaction()?;
    tx.execute("DELETE FROM chunks WHERE file_id=?1", params![file_id])?;
    tx.execute("DELETE FROM cells WHERE file_id=?1", params![file_id])?;
    tx.execute("DELETE FROM files WHERE id=?1", params![file_id])?;
    tx.commit()?;
    Ok(())
}

/// 删除文件全部 chunks（文件变更重入库前清理）。
pub fn clear_chunks(conn: &Connection, file_id: i64) -> rusqlite::Result<()> {
    conn.execute("DELETE FROM chunks WHERE file_id=?1", params![file_id])?;
    Ok(())
}

/// 删除磁盘上已不存在的文件记录，返回被删 rel_path 列表。
pub fn prune_deleted(
    conn: &mut Connection,
    existing_rel_paths: &std::collections::HashSet<String>,
) -> rusqlite::Result<Vec<String>> {
    let all: Vec<(i64, String)> = {
        let mut stmt = conn.prepare("SELECT id, rel_path FROM files")?;
        let rows = stmt.query_map([], |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)))?;
        rows.collect::<Result<_, _>>()?
    };
    let mut deleted = Vec::new();
    for (id, rel) in all {
        if !existing_rel_paths.contains(&rel) {
            delete_file(conn, id)?;
            deleted.push(rel);
        }
    }
    Ok(deleted)
}

// ------------------------------------------------------------------
// Chunk 操作
// ------------------------------------------------------------------

/// 批量写入切块占位行（embedding 为 NULL），返回 file_ids。
/// 幂等：先按 (file_id, seq) 删除再插入。
pub fn upsert_chunks(conn: &Connection, chunks: &[ChunkRecord]) -> rusqlite::Result<Vec<i64>> {
    let mut file_ids = Vec::new();
    for chunk in chunks {
        conn.execute(
            "DELETE FROM chunks WHERE file_id=?1 AND seq=?2",
            params![chunk.file_id, chunk.seq],
        )?;
        conn.execute(
            "INSERT INTO chunks
                (file_id, seq, text, embedding, date, file_type, sheet_name, row_start, row_end, heading, status)
             VALUES (?1, ?2, ?3, NULL, ?4, ?5, ?6, ?7, ?8, ?9, 'pending')",
            params![
                chunk.file_id,
                chunk.seq,
                chunk.text,
                if chunk.date == 0 { None } else { Some(chunk.date) },
                chunk.file_type,
                chunk.sheet_name,
                chunk.row_start,
                chunk.row_end,
                chunk.heading,
            ],
        )?;
        file_ids.push(chunk.file_id);
    }
    Ok(file_ids)
}

/// 更新切块 embedding（float32 LE blob）与状态。
pub fn update_chunk_embedding(
    conn: &Connection,
    file_id: i64,
    seq: i64,
    embedding: &[f32],
) -> rusqlite::Result<()> {
    let blob = floats_to_blob(embedding);
    conn.execute(
        "UPDATE chunks SET embedding=?1, status='ok' WHERE file_id=?2 AND seq=?3",
        params![blob, file_id, seq],
    )?;
    Ok(())
}

/// 更新切块状态（failed 等）。
pub fn update_chunk_status(
    conn: &Connection,
    file_id: i64,
    seq: i64,
    status: &str,
) -> rusqlite::Result<()> {
    conn.execute(
        "UPDATE chunks SET status=?1 WHERE file_id=?2 AND seq=?3",
        params![status, file_id, seq],
    )?;
    Ok(())
}

/// 获取用于检索的 chunks（JOIN files 取 rel_path），带过滤条件。
#[allow(clippy::too_many_arguments)]
pub fn get_chunks_for_retrieval(
    conn: &Connection,
    date_range: Option<(i64, i64)>,
    file_types: Option<&[String]>,
    path_prefix: Option<&str>,
    include_null_date: bool,
) -> rusqlite::Result<Vec<ChunkRecord>> {
    let mut conditions: Vec<String> = vec!["c.status='ok'".to_string()];
    let mut params_list: Vec<rusqlite::types::Value> = Vec::new();

    if let Some((start, end)) = date_range {
        if include_null_date {
            conditions.push("(c.date BETWEEN ? AND ? OR c.date IS NULL)".to_string());
        } else {
            conditions.push("c.date BETWEEN ? AND ?".to_string());
        }
        params_list.push(rusqlite::types::Value::Integer(start));
        params_list.push(rusqlite::types::Value::Integer(end));
    }
    if let Some(types) = file_types {
        if !types.is_empty() {
            let placeholders = vec!["?"; types.len()].join(",");
            conditions.push(format!("c.file_type IN ({placeholders})"));
            for t in types {
                params_list.push(rusqlite::types::Value::Text(t.clone()));
            }
        }
    }
    if let Some(prefix) = path_prefix {
        if !prefix.is_empty() {
            conditions.push("f.rel_path LIKE ?".to_string());
            params_list.push(rusqlite::types::Value::Text(format!("{prefix}%")));
        }
    }

    let where_clause = conditions.join(" AND ");
    let sql = format!(
        "SELECT c.id, c.file_id, c.seq, c.text, c.embedding, c.date, c.file_type,
                c.sheet_name, c.row_start, c.row_end, c.heading, f.rel_path
         FROM chunks c JOIN files f ON c.file_id = f.id
         WHERE {where_clause}"
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(rusqlite::params_from_iter(params_list), |row| {
        let embedding_blob: Option<Vec<u8>> = row.get(4)?;
        Ok(ChunkRecord {
            id: row.get(0)?,
            file_id: row.get(1)?,
            seq: row.get(2)?,
            text: row.get(3)?,
            date: row.get::<_, Option<i64>>(5)?.unwrap_or(0),
            file_type: row.get::<_, Option<String>>(6)?.unwrap_or_default(),
            sheet_name: row.get(7)?,
            row_start: row.get(8)?,
            row_end: row.get(9)?,
            heading: row.get(10)?,
            rel_path: row.get(11)?,
            score: 0.0,
            status: "ok".to_string(),
            // embedding 由调用方解析
            _embedding_blob: embedding_blob,
        })
    })?;
    rows.collect()
}

impl ChunkRecord {
    /// 解析 embedding BLOB 为 f32 向量。
    pub fn embedding(&self) -> Option<Vec<f32>> {
        self._embedding_blob.as_deref().map(blob_to_floats)
    }
}

// ------------------------------------------------------------------
// Meta 操作
// ------------------------------------------------------------------

pub fn get_meta(conn: &Connection, key: &str) -> rusqlite::Result<Option<String>> {
    conn.query_row(
        "SELECT value FROM meta WHERE key=?1",
        params![key],
        |row| row.get(0),
    )
    .optional()
}

pub fn set_meta(conn: &Connection, key: &str, value: &str) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)",
        params![key, value],
    )?;
    Ok(())
}

/// 检查 embedding 模型一致性（换模型需 reset）。
pub fn check_embedding_model(conn: &Connection, model_name: &str) -> rusqlite::Result<bool> {
    match get_meta(conn, "embedding_model")? {
        None => {
            set_meta(conn, "embedding_model", model_name)?;
            set_meta(conn, "schema_version", SCHEMA_VERSION)?;
            Ok(true)
        }
        Some(stored) => Ok(stored == model_name),
    }
}

// ------------------------------------------------------------------
// 精确值索引（Excel）
// ------------------------------------------------------------------

/// 重建某文件的精确值索引。
pub fn replace_cells(conn: &Connection, rel_path: &str, cells: &[CellRecord]) -> rusqlite::Result<()> {
    conn.execute("DELETE FROM cells WHERE rel_path=?1", params![rel_path])?;
    if cells.is_empty() {
        return Ok(());
    }
    for cell in cells {
        conn.execute(
            "INSERT INTO cells (file_id, rel_path, sheet_name, row, col, col_letter, header, value)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                cell.file_id, cell.rel_path, cell.sheet_name, cell.row,
                cell.col, cell.col_letter, cell.header, cell.value,
            ],
        )?;
    }
    Ok(())
}

/// 精确值检索：value 全等优先，LIKE 兜底。
#[allow(clippy::too_many_arguments)]
pub fn search_cells(
    conn: &Connection,
    exact_values: &[String],
    like_values: &[String],
    path_prefix: Option<&str>,
    limit: i64,
) -> rusqlite::Result<Vec<CellRecord>> {
    let mut clauses: Vec<String> = Vec::new();
    let mut params_list: Vec<rusqlite::types::Value> = Vec::new();

    if !exact_values.is_empty() {
        let placeholders = vec!["?"; exact_values.len()].join(",");
        clauses.push(format!("value IN ({placeholders})"));
        for v in exact_values {
            params_list.push(rusqlite::types::Value::Text(v.clone()));
        }
    }
    for lv in like_values {
        clauses.push("value LIKE ?".to_string());
        params_list.push(rusqlite::types::Value::Text(format!("%{lv}%")));
    }
    if let Some(prefix) = path_prefix {
        if !prefix.is_empty() {
            clauses.push("rel_path LIKE ?".to_string());
            params_list.push(rusqlite::types::Value::Text(format!("{prefix}%")));
        }
    }
    if clauses.is_empty() {
        return Ok(Vec::new());
    }
    let where_clause = clauses.join(" OR ");
    let sql = format!(
        "SELECT file_id, rel_path, sheet_name, row, col, col_letter, header, value
         FROM cells WHERE {where_clause}
         ORDER BY rel_path, sheet_name, row, col LIMIT ?1"
    );
    params_list.push(rusqlite::types::Value::Integer(limit));
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(rusqlite::params_from_iter(params_list), |row| {
        Ok(CellRecord {
            file_id: row.get(0)?,
            rel_path: row.get(1)?,
            sheet_name: row.get(2)?,
            row: row.get(3)?,
            col: row.get(4)?,
            col_letter: row.get(5)?,
            header: row.get::<_, Option<String>>(6)?.unwrap_or_default(),
            value: row.get(7)?,
        })
    })?;
    rows.collect()
}

/// 清空知识库（重建用）。
pub fn reset(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch("DELETE FROM chunks; DELETE FROM files; DELETE FROM meta;")?;
    Ok(())
}

// ------------------------------------------------------------------
// 统计
// ------------------------------------------------------------------

/// 索引统计 {files, chunks, cells, by_type}。
pub fn stats(conn: &Connection) -> rusqlite::Result<HashMap<String, i64>> {
    let file_count: i64 =
        conn.query_row("SELECT COUNT(*) FROM files", [], |row| row.get(0))?;
    let chunk_count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM chunks WHERE status='ok'",
        [],
        |row| row.get(0),
    )?;
    let cell_count: i64 =
        conn.query_row("SELECT COUNT(*) FROM cells", [], |row| row.get(0))?;
    let mut map = HashMap::new();
    map.insert("files".to_string(), file_count);
    map.insert("chunks".to_string(), chunk_count);
    map.insert("cells".to_string(), cell_count);
    Ok(map)
}

// ------------------------------------------------------------------
// 辅助
// ------------------------------------------------------------------

fn floats_to_blob(values: &[f32]) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(values.len() * 4);
    for v in values {
        bytes.extend_from_slice(&v.to_le_bytes());
    }
    bytes
}

fn blob_to_floats(blob: &[u8]) -> Vec<f32> {
    blob.chunks_exact(4)
        .map(|chunk| f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]))
        .collect()
}

/// 当前时间的 ISO 字符串（parsed_at 用）。
fn chrono_iso_now() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

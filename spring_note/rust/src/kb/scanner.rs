//! 扫描器 — 目录递归、白名单扩展名、增量判重、日期提取。
//!
//! 与 sidecar scanner 对齐：
//! - 数据源：notes/ 业务区（相对数据目录） + 外部文件夹（绝对路径）
//! - 增量判重：size+mtime 快速跳过 → sha256 确认 → 变更/新增
//! - 黑名单目录/扩展名排除

use super::store::{self, FileRecord};
use super::utils;
use rusqlite::Connection;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

/// 扫描配置。
#[derive(Clone, Debug)]
pub struct ScanConfig {
    pub sources: Vec<String>,
    pub exclude_dirs: Vec<String>,
    pub exclude_exts: Vec<String>,
    pub max_file_mb: i64,
}

impl Default for ScanConfig {
    fn default() -> Self {
        Self {
            sources: vec!["notes".to_string(), "业务".to_string()],
            exclude_dirs: vec![".git".to_string(), ".reasonix".to_string()],
            exclude_exts: vec![
                "png".into(), "jpeg".into(), "jpg".into(), "mp4".into(),
                "zip".into(), "xmind".into(), "ini".into(),
            ],
            max_file_mb: 50,
        }
    }
}

/// 扫描结果。
#[derive(Clone, Debug, Default)]
pub struct ScanResult {
    pub total_files: usize,
    pub new_files: Vec<PathBuf>,
    pub changed_files: Vec<PathBuf>,
    pub skipped_files: Vec<PathBuf>,
    pub excluded_files: Vec<String>,
    pub deleted_rel_paths: Vec<String>,
}

/// 递归扫描数据目录，返回增量判重结果。
pub fn scan(data_dir: &Path, cfg: &ScanConfig, conn: &Connection) -> ScanResult {
    let mut result = ScanResult::default();
    let mut all_files: Vec<PathBuf> = Vec::new();

    for source in &cfg.sources {
        let source_path = if Path::new(source).is_absolute() {
            PathBuf::from(source)
        } else {
            data_dir.join(source)
        };
        if !source_path.exists() {
            continue;
        }
        let mut files = Vec::new();
        walk(&source_path, cfg, &mut files);
        all_files.extend(files);
    }

    result.total_files = all_files.len();

    // 增量判重
    let existing = match store::get_all_files(conn) {
        Ok(map) => map,
        Err(_) => HashMap::new(),
    };
    let existing_rel_paths: HashSet<String> = existing.keys().cloned().collect();
    let mut disk_rel_paths: HashSet<String> = HashSet::new();

    for fpath in &all_files {
        let rel = match fpath.strip_prefix(data_dir) {
            Ok(rel) => rel.to_string_lossy().replace('\\', "/"),
            Err(_) => external_rel(fpath, data_dir),
        };
        disk_rel_paths.insert(rel.clone());

        if is_excluded(&rel, cfg) {
            result.excluded_files.push(rel);
            continue;
        }

        let record = existing.get(&rel);
        let meta = match fpath.metadata() {
            Ok(m) => m,
            Err(_) => continue,
        };
        let size = meta.len() as i64;
        let mtime_ns = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_nanos() as i64)
            .unwrap_or(0);

        match record {
            Some(rec) if rec.size_bytes == size && rec.mtime_ns == mtime_ns => {
                result.skipped_files.push(fpath.clone());
            }
            Some(rec) => {
                // mtime 变了 → 算 sha256 确认
                if let Ok(hash) = utils::file_sha256(fpath) {
                    if hash == rec.file_hash {
                        let _ = store::update_mtime(conn, rec.id, mtime_ns);
                        result.skipped_files.push(fpath.clone());
                    } else {
                        result.changed_files.push(fpath.clone());
                    }
                } else {
                    result.changed_files.push(fpath.clone());
                }
            }
            None => {
                result.new_files.push(fpath.clone());
            }
        }
    }

    // 检测已删除文件
    result.deleted_rel_paths = existing_rel_paths
        .difference(&disk_rel_paths)
        .cloned()
        .collect::<Vec<_>>();
    result.deleted_rel_paths.sort();

    result
}

/// 外部知识库文件夹的相对路径：{目录名}/{相对路径}。
fn external_rel(fpath: &Path, data_dir: &Path) -> String {
    let abs = fpath.canonicalize().unwrap_or_else(|_| fpath.to_path_buf());
    if let Ok(rel) = abs.strip_prefix(data_dir) {
        return rel.to_string_lossy().replace('\\', "/");
    }
    fpath
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| fpath.to_string_lossy().to_string())
}

/// 递归收集白名单扩展名文件。
fn walk(base: &Path, cfg: &ScanConfig, results: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(base) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with('.') || cfg.exclude_dirs.iter().any(|d| d.eq_ignore_ascii_case(&name)) {
            continue;
        }
        if path.is_dir() {
            walk(&path, cfg, results);
        } else if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
            let ext_lower = ext.to_lowercase();
            if is_supported_ext(&ext_lower) && !cfg.exclude_exts.contains(&ext_lower) {
                if let Ok(meta) = path.metadata() {
                    if meta.len() <= (cfg.max_file_mb * 1024 * 1024) as u64 {
                        results.push(path);
                    }
                }
            }
        }
    }
}

/// 支持的解析扩展名。
fn is_supported_ext(ext: &str) -> bool {
    matches!(ext, "md" | "txt" | "xlsx" | "xls" | "docx" | "pdf")
}

/// 路径是否应被排除（黑名单目录/扩展名）。
fn is_excluded(rel: &str, cfg: &ScanConfig) -> bool {
    for dir in &cfg.exclude_dirs {
        if rel.starts_with(&format!("{dir}/")) {
            return true;
        }
    }
    if let Some(ext) = rel.rsplit('.').next() {
        let ext_lower = ext.to_lowercase();
        if cfg.exclude_exts.contains(&ext_lower) {
            return true;
        }
    }
    false
}

/// 将扫描结果中的文件转为待解析文档清单（含日期/哈希）。
pub fn build_file_records(
    files: &[PathBuf],
    data_dir: &Path,
) -> Vec<(PathBuf, FileRecord)> {
    files
        .iter()
        .filter_map(|fpath| {
            let rel = match fpath.strip_prefix(data_dir) {
                Ok(rel) => rel.to_string_lossy().replace('\\', "/"),
                Err(_) => external_rel(fpath, data_dir),
            };
            let meta = fpath.metadata().ok()?;
            let (date, date_source) = utils::extract_date_from_path(fpath);
            let hash = utils::file_sha256(fpath).unwrap_or_default();
            Some((
                fpath.clone(),
                FileRecord {
                    id: 0,
                    rel_path: rel,
                    file_hash: hash,
                    size_bytes: meta.len() as i64,
                    mtime_ns: meta
                        .modified()
                        .ok()
                        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                        .map(|d| d.as_nanos() as i64)
                        .unwrap_or(0),
                    date: date.unwrap_or(0),
                    date_source: date_source.to_string(),
                    status: "ok".to_string(),
                },
            ))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scans_and_deduplicates() {
        let dir = std::env::temp_dir().join(format!("xyn_scan_{}", std::process::id()));
        std::fs::create_dir_all(dir.join("notes/daily")).unwrap();
        std::fs::write(dir.join("notes/daily/2026-08-01.md"), "# 日报").unwrap();
        std::fs::write(dir.join("notes/daily/2026-08-02.md"), "# 日报2").unwrap();

        let conn = store::open_store(&dir).unwrap();
        let cfg = ScanConfig::default();
        let result = scan(&dir, &cfg, &conn);
        assert_eq!(result.total_files, 2);
        assert_eq!(result.new_files.len(), 2);

        // 入库
        let records = build_file_records(&result.new_files, &dir);
        for (_, record) in &records {
            let _ = store::upsert_file(&conn, record);
        }
        // 二次扫描：全部跳过
        let result2 = scan(&dir, &cfg, &conn);
        assert_eq!(result2.skipped_files.len(), 2);
        assert_eq!(result2.new_files.len(), 0);

        // 修改文件 → 变更
        std::fs::write(dir.join("notes/daily/2026-08-01.md"), "# 日报（改）").unwrap();
        let result3 = scan(&dir, &cfg, &conn);
        assert_eq!(result3.changed_files.len(), 1);

        // 删除文件 → 检测删除
        std::fs::remove_file(dir.join("notes/daily/2026-08-02.md")).unwrap();
        let result4 = scan(&dir, &cfg, &conn);
        assert!(result4.deleted_rel_paths.iter().any(|p| p.contains("2026-08-02")));

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn excludes_blacklist_dirs() {
        let dir = std::env::temp_dir().join(format!("xyn_scan_ex_{}", std::process::id()));
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        std::fs::create_dir_all(dir.join("notes")).unwrap();
        std::fs::write(dir.join(".git/config"), "x").unwrap();
        std::fs::write(dir.join("notes/readme.md"), "# n").unwrap();

        let conn = store::open_store(&dir).unwrap();
        let cfg = ScanConfig::default();
        let result = scan(&dir, &cfg, &conn);
        assert_eq!(result.total_files, 1); // .git/config 被排除

        std::fs::remove_dir_all(&dir).ok();
    }
}

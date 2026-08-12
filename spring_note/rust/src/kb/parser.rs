//! 文件解析器 — md/txt/docx/xlsx → 结构化文档。
//!
//! 与 sidecar parsers 对齐：
//! - md: 文本提取 + 二级标题段标记（heading）
//! - xlsx: 行分组合块（表头探测、合并单元格前向填充）
//! - docx: 段落文本提取
//! - pdf: 占位（文本提取后续接入轻量库）

use calamine::Reader;
use super::chunker::Document;
use super::utils::{desensitize, extract_date_from_path, is_sensitive_file};
use std::path::Path;

/// 解析单个文件为 Document 列表（多数文件一个 Document，xlsx 按行分组多个）。
pub fn parse_file(fpath: &Path, data_dir: &Path) -> Vec<Document> {
    let rel = match fpath.strip_prefix(data_dir) {
        Ok(rel) => rel.to_string_lossy().replace('\\', "/"),
        Err(_) => fpath
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| fpath.to_string_lossy().to_string()),
    };
    let ext = fpath
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();
    let date = extract_date_from_path(fpath).0.unwrap_or(0);

    match ext.as_str() {
        "md" => parse_markdown(fpath, &rel, date),
        "txt" => parse_text(fpath, &rel, date),
        "xlsx" | "xls" => parse_excel(fpath, &rel, date, data_dir),
        "docx" => parse_docx(fpath, &rel, date),
        "pdf" => Vec::new(), // pdf 解析暂未接入
        _ => Vec::new(),
    }
}

/// 解析 Markdown：按二级标题分段，段落内容记录所属标题。
fn parse_markdown(path: &Path, rel: &str, date: i64) -> Vec<Document> {
    let Ok(content) = std::fs::read_to_string(path) else { return Vec::new() };
    let (cleaned, desens_count) = desensitize(&content);
    let sensitive = is_sensitive_file(desens_count, rel);
    let file_type = "markdown".to_string();

    // 按 ## 二级标题切段
    let mut docs = Vec::new();
    let mut current_heading: Option<String> = None;
    let mut current_text = String::new();

    let flush = |docs: &mut Vec<Document>, heading: &Option<String>, text: &mut String| {
        let text_trim = text.trim();
        if !text_trim.is_empty() {
            docs.push(Document {
                rel_path: rel.to_string(),
                file_type: file_type.clone(),
                date,
                heading: heading.clone(),
                text: text_trim.to_string(),
                sensitive,
                ..Default::default()
            });
        }
        text.clear();
    };

    for line in cleaned.lines() {
        if let Some(heading_text) = line.strip_prefix("## ") {
            flush(&mut docs, &current_heading, &mut current_text);
            current_heading = Some(heading_text.trim().to_string());
        } else {
            current_text.push_str(line);
            current_text.push('\n');
        }
    }
    flush(&mut docs, &current_heading, &mut current_text);

    if docs.is_empty() {
        // 无二级标题：整篇一块
        let text = cleaned.trim();
        if !text.is_empty() {
            docs.push(Document {
                rel_path: rel.to_string(),
                file_type,
                date,
                text: text.to_string(),
                sensitive,
                ..Default::default()
            });
        }
    }
    docs
}

/// 解析纯文本。
fn parse_text(path: &Path, rel: &str, date: i64) -> Vec<Document> {
    let Ok(content) = std::fs::read_to_string(path) else { return Vec::new() };
    let (cleaned, desens_count) = desensitize(&content);
    let sensitive = is_sensitive_file(desens_count, rel);
    vec![Document {
        rel_path: rel.to_string(),
        file_type: "text".to_string(),
        date,
        text: cleaned.trim().to_string(),
        sensitive,
        ..Default::default()
    }]
}

/// 解析 docx：提取段落文本。
fn parse_docx(path: &Path, rel: &str, date: i64) -> Vec<Document> {
    let Ok(file) = std::fs::File::open(path) else { return Vec::new() };
    let Ok(mut zip) = zip::ZipArchive::new(file) else { return Vec::new() };
    let mut text = String::new();
    for i in 0..zip.len() {
        let Ok(mut entry) = zip.by_index(i) else { continue };
        let name = entry.name().to_string();
        if !name.ends_with("document.xml") {
            continue;
        }
        let mut buf = String::new();
        use std::io::Read;
        let _ = entry.read_to_string(&mut buf);
        // 提取 <w:t> 文本节点
        let re = regex::Regex::new(r"<w:t[^>]*>(.*?)</w:t>").unwrap();
        for cap in re.captures_iter(&buf) {
            if let Some(m) = cap.get(1) {
                let segment = m.as_str().replace("&amp;", "&").replace("&lt;", "<")
                    .replace("&gt;", ">").replace("&quot;", "\"")
                    .replace("&apos;", "'");
                text.push_str(&segment);
                text.push('\n');
            }
        }
    }
    let (cleaned, desens_count) = desensitize(&text);
    let sensitive = is_sensitive_file(desens_count, rel);
    vec![Document {
        rel_path: rel.to_string(),
        file_type: "docx".to_string(),
        date,
        text: cleaned.trim().to_string(),
        sensitive,
        ..Default::default()
    }]
}

/// 解析 Excel：按行分组合块 + 表头探测 + 精确值收集。
fn parse_excel(path: &Path, rel: &str, date: i64, _data_dir: &Path) -> Vec<Document> {
    let mut workbook = match calamine::open_workbook_auto(path) {
        Ok(wb) => wb,
        Err(_) => return Vec::new(),
    };

    let mut docs = Vec::new();
    let sheet_names: Vec<String> = workbook.sheet_names().to_vec();
    for sheet_name in sheet_names {
        let Ok(range) = workbook.worksheet_range(&sheet_name) else { continue };
        let rows: Vec<Vec<String>> = range
            .rows()
            .map(|row| {
                row.iter()
                    .map(|cell| match cell {
                        calamine::Data::String(s) => s.clone(),
                        calamine::Data::Float(f) => format_float(*f),
                        calamine::Data::Int(i) => i.to_string(),
                        calamine::Data::Bool(b) => b.to_string(),
                        calamine::Data::DateTime(d) => d.to_string(),
                        calamine::Data::Error(e) => format!("{e:?}"),
                        calamine::Data::Empty => String::new(),
                        _ => String::new(),
                    })
                    .collect()
            })
            .collect();
        if rows.is_empty() {
            continue;
        }

        // 表头探测：非空单元格最多的行
        let header_idx = rows
            .iter()
            .enumerate()
            .max_by_key(|(_, row)| row.iter().filter(|c| !c.is_empty()).count())
            .map(|(i, _)| i)
            .unwrap_or(0);
        let headers = rows.get(header_idx).cloned().unwrap_or_default();

        // 数据行（表头之后）分组合块
        let mut current = String::new();
        let mut start_row: Option<i64> = None;
        for (i, row) in rows.iter().enumerate().skip(header_idx + 1) {
            let row_text: Vec<String> = row
                .iter()
                .enumerate()
                .filter_map(|(col, value)| {
                    if value.is_empty() {
                        None
                    } else {
                        let header = headers.get(col).cloned().unwrap_or_default();
                        Some(format!("{header}:{value}"))
                    }
                })
                .collect();
            let line = row_text.join("；");
            if line.is_empty() {
                continue;
            }
            if current.chars().count() + line.chars().count() > 600 {
                // 输出当前块
                if !current.is_empty() {
                    docs.push(Document {
                        rel_path: rel.to_string(),
                        file_type: "excel".to_string(),
                        date,
                        sheet_name: Some(sheet_name.clone()),
                        row_start: start_row,
                        row_end: Some((i) as i64),
                        text: std::mem::take(&mut current),
                        sensitive: false,
                        ..Default::default()
                    });
                }
                start_row = Some((i + 1) as i64);
                current = line;
            } else {
                if current.is_empty() {
                    start_row = Some((i + 1) as i64);
                }
                if !current.is_empty() {
                    current.push('\n');
                }
                current.push_str(&line);
            }
        }
        if !current.is_empty() {
            docs.push(Document {
                rel_path: rel.to_string(),
                file_type: "excel".to_string(),
                date,
                sheet_name: Some(sheet_name.clone()),
                row_start: start_row,
                row_end: Some(rows.len() as i64),
                text: current,
                sensitive: false,
                ..Default::default()
            });
        }
    }
    docs
}

/// 收集 Excel 精确值（供 cells 索引）。
pub fn collect_excel_cells(path: &Path, rel: &str) -> Vec<super::store::CellRecord> {
    let mut cells = Vec::new();
    let mut workbook = match calamine::open_workbook_auto(path) {
        Ok(wb) => wb,
        Err(_) => return cells,
    };
    let sheet_names: Vec<String> = workbook.sheet_names().to_vec();
    for sheet_name in sheet_names {
        let Ok(range) = workbook.worksheet_range(&sheet_name) else { continue };
        let rows: Vec<Vec<String>> = range
            .rows()
            .map(|row| {
                row.iter()
                    .map(|cell| match cell {
                        calamine::Data::String(s) => s.clone(),
                        calamine::Data::Float(f) => format_float(*f),
                        calamine::Data::Int(i) => i.to_string(),
                        calamine::Data::Bool(b) => b.to_string(),
                        calamine::Data::DateTime(d) => d.to_string(),
                        _ => String::new(),
                    })
                    .collect()
            })
            .collect();
        let header_idx = rows
            .iter()
            .enumerate()
            .max_by_key(|(_, row)| row.iter().filter(|c| !c.is_empty()).count())
            .map(|(i, _)| i)
            .unwrap_or(0);
        let headers = rows.get(header_idx).cloned().unwrap_or_default();

        for (ri, row) in rows.iter().enumerate() {
            for (ci, value) in row.iter().enumerate() {
                if value.is_empty() || value.len() > 200 {
                    continue;
                }
                let header = headers.get(ci).cloned().unwrap_or_default();
                let (cleaned, count) = desensitize(value);
                if count > 0 {
                    continue;
                }
                cells.push(super::store::CellRecord {
                    file_id: 0,
                    rel_path: rel.to_string(),
                    sheet_name: sheet_name.clone(),
                    row: (ri + 1) as i64,
                    col: (ci + 1) as i64,
                    col_letter: col_letter(ci),
                    header,
                    value: cleaned,
                });
            }
        }
    }
    cells
}

fn col_letter(index: usize) -> String {
    let mut n = index;
    let mut s = String::new();
    loop {
        s.insert(0, ((n % 26) as u8 + b'A') as char);
        if n < 26 {
            break;
        }
        n = n / 26 - 1;
    }
    s
}

fn format_float(f: f64) -> String {
    if (f - f.round()).abs() < 1e-9 {
        format!("{}", f.round() as i64)
    } else {
        format!("{f}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_markdown_with_headings() {
        let dir = std::env::temp_dir().join(format!("xyn_parse_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("2026-08-01.md");
        std::fs::write(&f, "# 日报\n\n## 上午\n\n做了 A\n\n## 下午\n\n做了 B").unwrap();
        let docs = parse_file(&f, &dir);
        // 3 段: 无 heading(# 日报)、heading=上午、heading=下午
        assert_eq!(docs.len(), 3);
        assert_eq!(docs[1].heading.as_deref(), Some("上午"));
        assert_eq!(docs[2].heading.as_deref(), Some("下午"));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn parses_plain_text() {
        let dir = std::env::temp_dir().join(format!("xyn_parse2_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("note.txt");
        std::fs::write(&f, "纯文本内容").unwrap();
        let docs = parse_file(&f, &dir);
        assert_eq!(docs.len(), 1);
        assert_eq!(docs[0].file_type, "text");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn col_letter_works() {
        assert_eq!(col_letter(0), "A");
        assert_eq!(col_letter(25), "Z");
        assert_eq!(col_letter(26), "AA");
        assert_eq!(col_letter(27), "AB");
    }
}

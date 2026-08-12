//! 切块器 — 结构化切块 + 字符窗口回退（与 sidecar chunker 对齐）。
//!
//! 规则：
//! - 结构化块（Excel 行分组合块、md 二级标题段、docx 标题段落）不再切；
//! - 超长块走滑动窗口回退，重叠 size × overlap_ratio；
//! - min_size 仅对字符窗口回退切块生效，结构化块豁免。

use super::store::ChunkRecord;

/// 切块配置。
#[derive(Clone, Debug)]
pub struct ChunkConfig {
    pub size: usize,
    pub overlap_ratio: f64,
    pub min_size: usize,
}

impl Default for ChunkConfig {
    fn default() -> Self {
        Self { size: 600, overlap_ratio: 0.1, min_size: 50 }
    }
}

/// 待切块文档。
#[derive(Clone, Debug, Default)]
pub struct Document {
    pub rel_path: String,
    pub file_type: String,
    pub date: i64,
    pub sheet_name: Option<String>,
    pub row_start: Option<i64>,
    pub row_end: Option<i64>,
    pub heading: Option<String>,
    pub text: String,
    pub sensitive: bool,
}

/// 对 Document 列表执行切块，返回 Chunk 列表。
pub fn chunk_documents(docs: &[Document], cfg: &ChunkConfig) -> Vec<ChunkRecord> {
    let mut result = Vec::new();
    let mut seq = 0i64;
    for doc in docs {
        if doc.sensitive {
            continue;
        }
        let chunks = chunk_single(doc, cfg);
        for mut chunk in chunks {
            chunk.seq = seq;
            seq += 1;
            result.push(chunk);
        }
    }
    result
}

/// 单文档切块。
fn chunk_single(doc: &Document, cfg: &ChunkConfig) -> Vec<ChunkRecord> {
    let text = doc.text.trim();
    if text.is_empty() {
        return Vec::new();
    }
    // 结构化块：长度在 size 上限内 → 直接作为一块
    if text.chars().count() <= cfg.size {
        if text.chars().count() < cfg.min_size && doc.file_type == "text" {
            return Vec::new();
        }
        return vec![make_chunk(doc, text.to_string())];
    }
    // 超长块：按文件类型选择断句策略后走滑动窗口
    let units = split_to_units(&doc.file_type, text);
    sliding_window(&units, doc, cfg)
}

/// 按文件类型拆分基本单元。
fn split_to_units(file_type: &str, text: &str) -> Vec<String> {
    if file_type == "markdown" || file_type == "text" {
        text.split("\n\n")
            .map(|p| p.trim().to_string())
            .filter(|p| !p.is_empty())
            .collect()
    } else {
        // 按句号或换行断开
        let mut parts = Vec::new();
        let mut current = String::new();
        for ch in text.chars() {
            current.push(ch);
            if ch == '。' || ch == '！' || ch == '？' || ch == '\n' {
                let trimmed = current.trim().to_string();
                if !trimmed.is_empty() {
                    parts.push(trimmed);
                }
                current.clear();
            }
        }
        let trimmed = current.trim().to_string();
        if !trimmed.is_empty() {
            parts.push(trimmed);
        }
        parts
    }
}

/// 滑动窗口切块。
fn sliding_window(units: &[String], doc: &Document, cfg: &ChunkConfig) -> Vec<ChunkRecord> {
    let mut chunks: Vec<ChunkRecord> = Vec::new();
    let overlap = (cfg.size as f64 * cfg.overlap_ratio) as usize;
    let mut current = String::new();

    for unit in units {
        // 单单元超过窗口上限：先输出已有缓冲区，再字符级拆分
        if unit.chars().count() > cfg.size {
            if !current.is_empty() && current.chars().count() >= cfg.min_size {
                chunks.push(make_chunk(doc, std::mem::take(&mut current)));
            }
            for seg in split_long_unit(unit, cfg) {
                if !seg.is_empty() {
                    chunks.push(make_chunk(doc, seg));
                }
            }
            current.clear();
            continue;
        }

        let candidate = if current.is_empty() {
            unit.clone()
        } else {
            format!("{current}\n{unit}")
        };

        if candidate.chars().count() <= cfg.size {
            current = candidate;
        } else {
            if !current.is_empty() && current.chars().count() >= cfg.min_size {
                chunks.push(make_chunk(doc, std::mem::take(&mut current)));
            }
            let carry: String = if overlap > 0 {
                current.chars().rev().take(overlap).collect::<Vec<_>>().into_iter().rev().collect()
            } else {
                String::new()
            };
            current = if carry.is_empty() {
                unit.clone()
            } else {
                format!("{carry}\n{unit}")
            };
        }
    }

    if !current.is_empty() && current.chars().count() >= cfg.min_size {
        chunks.push(make_chunk(doc, current));
    }
    chunks
}

/// 超长单元按字符窗口拆分（带重叠），过短的尾段并入最后一块。
fn split_long_unit(unit: &str, cfg: &ChunkConfig) -> Vec<String> {
    let chars: Vec<char> = unit.chars().collect();
    let size = cfg.size;
    let overlap = (size as f64 * cfg.overlap_ratio) as usize;
    let step = size.saturating_sub(overlap).max(1);
    let mut parts: Vec<String> = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        let end = (i + size).min(chars.len());
        let seg: String = chars[i..end].iter().collect();
        if !parts.is_empty() && seg.chars().count() < cfg.min_size {
            parts.last_mut().unwrap().push_str(&seg);
        } else {
            parts.push(seg);
        }
        i += step;
    }
    parts
}

fn make_chunk(doc: &Document, text: String) -> ChunkRecord {
    ChunkRecord {
        id: 0,
        file_id: 0,
        seq: 0,
        text,
        date: doc.date,
        file_type: doc.file_type.clone(),
        sheet_name: doc.sheet_name.clone(),
        row_start: doc.row_start,
        row_end: doc.row_end,
        heading: doc.heading.clone(),
        status: "ok".to_string(),
        rel_path: doc.rel_path.clone(),
        score: 0.0,
        _embedding_blob: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn doc(text: &str, file_type: &str) -> Document {
        Document {
            rel_path: "x.md".to_string(),
            file_type: file_type.to_string(),
            text: text.to_string(),
            ..Default::default()
        }
    }

    #[test]
    fn short_document_stays_single_chunk() {
        let cfg = ChunkConfig::default();
        let d = doc("简短内容", "markdown");
        let chunks = chunk_documents(&[d], &cfg);
        assert_eq!(chunks.len(), 1);
    }

    #[test]
    fn short_text_below_min_size_dropped() {
        let cfg = ChunkConfig::default();
        let d = doc("太短", "text");
        let chunks = chunk_documents(&[d], &cfg);
        assert_eq!(chunks.len(), 0);
    }

    #[test]
    fn structured_block_exempt_from_min_size() {
        let cfg = ChunkConfig::default();
        let mut d = doc("短", "markdown");
        d.heading = Some("标题".to_string());
        let chunks = chunk_documents(&[d], &cfg);
        assert_eq!(chunks.len(), 1);
    }

    #[test]
    fn long_document_slides_with_overlap() {
        let cfg = ChunkConfig { size: 100, overlap_ratio: 0.1, min_size: 20 };
        let long_text = "段落内容".repeat(50);
        let d = doc(&long_text, "text");
        let chunks = chunk_documents(&[d], &cfg);
        assert!(chunks.len() > 1);
        for chunk in &chunks {
            assert!(chunk.text.chars().count() <= 100);
        }
    }

    #[test]
    fn sensitive_document_skipped() {
        let cfg = ChunkConfig::default();
        let mut d = doc("内容", "markdown");
        d.sensitive = true;
        let chunks = chunk_documents(&[d], &cfg);
        assert_eq!(chunks.len(), 0);
    }

    #[test]
    fn seq_is_global() {
        let cfg = ChunkConfig::default();
        let docs = vec![doc("第一份", "markdown"), doc("第二份", "markdown")];
        let chunks = chunk_documents(&docs, &cfg);
        assert_eq!(chunks[0].seq, 0);
        assert_eq!(chunks[1].seq, 1);
    }
}

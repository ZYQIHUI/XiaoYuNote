//! 检索层 — 时间词解析 → query 向量化 → 余弦 top-k → 来源多样性过滤。

use super::embedder::{self, EmbedConfig};
use super::store::{self, ChunkRecord};
use rusqlite::Connection;

/// 检索配置。
#[derive(Clone, Debug)]
pub struct RetrievalConfig {
    pub top_k: usize,
    pub max_per_file: usize,
    pub include_null_date: bool,
}

impl Default for RetrievalConfig {
    fn default() -> Self {
        Self { top_k: 5, max_per_file: 2, include_null_date: true }
    }
}

/// 检索结果项。
#[derive(Clone, Debug)]
pub struct RetrievedChunk {
    pub chunk: ChunkRecord,
    pub score: f32,
}

/// 执行检索：时间词解析 → query 向量化 → 余弦 top-k → 来源多样性。
pub async fn topk(
    conn: &Connection,
    cfg: &RetrievalConfig,
    embed: &EmbedConfig,
    query: &str,
    date_range: Option<(i64, i64)>,
    path_prefix: Option<&str>,
) -> Result<Vec<RetrievedChunk>, String> {
    // 1) 时间词解析
    let date_range = match date_range {
        Some(range) => Some(range),
        None => {
            let today = chrono::Local::now().date_naive();
            super::utils::parse_time_query(query, today)
        }
    };

    // 2) 候选 chunks
    let candidates = store::get_chunks_for_retrieval(
        conn,
        date_range,
        None,
        path_prefix,
        cfg.include_null_date,
    )
    .map_err(|e| format!("检索候选加载失败: {e}"))?;

    if candidates.is_empty() {
        return Ok(Vec::new());
    }

    // 3) query 向量化
    let query_vec = embedder::embed_one(embed, query)
        .await
        .map_err(|e| format!("查询向量化失败: {e}"))?;

    // 4) 余弦相似度（embedding 已 L2 归一化 ⇒ 点积即余弦）
    let mut scored: Vec<(f32, usize)> = Vec::with_capacity(candidates.len());
    for (i, cand) in candidates.iter().enumerate() {
        if let Some(embedding) = cand.embedding() {
            let dot: f32 = embedding
                .iter()
                .zip(query_vec.iter())
                .map(|(a, b)| a * b)
                .sum();
            scored.push((dot, i));
        }
    }
    scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));

    // 5) 来源多样性：每文件最多 max_per_file
    let mut selected = Vec::new();
    let mut file_counts: std::collections::HashMap<i64, usize> = std::collections::HashMap::new();
    for (score, idx) in scored {
        if selected.len() >= cfg.top_k {
            break;
        }
        let cand = &candidates[idx];
        let count = file_counts.entry(cand.file_id).or_insert(0);
        if *count >= cfg.max_per_file {
            continue;
        }
        *count += 1;
        let mut chunk = cand.clone();
        chunk.score = score;
        selected.push(RetrievedChunk { chunk, score });
    }

    Ok(selected)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_kb_returns_empty() {
        let dir = std::env::temp_dir().join(format!("xyn_retr_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let conn = store::open_store(&dir).unwrap();
        let cfg = RetrievalConfig::default();
        let embed = EmbedConfig::default();
        let rt = tokio::runtime::Runtime::new().unwrap();
        let result = rt.block_on(topk(&conn, &cfg, &embed, "测试", None, None));
        // 未配置 embedding → NotConfigured 错误（库空时直接返回空）
        assert!(result.is_ok());
        assert!(result.unwrap().is_empty());
        std::fs::remove_dir_all(&dir).ok();
    }
}

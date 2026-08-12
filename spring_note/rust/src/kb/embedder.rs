//! 向量化层 — OpenAI 兼容 embedding API 客户端。
//!
//! 批量调用、L2 归一化、维度校验、错误分类（与 sidecar embedder 对齐）。

use serde_json::json;
use std::time::Duration;

/// Embedding 配置。
#[derive(Clone, Debug)]
pub struct EmbedConfig {
    pub base_url: String,
    pub api_key: String,
    pub model: String,
    pub dim: usize,
    pub batch_size: usize,
    pub timeout_secs: u64,
}

impl Default for EmbedConfig {
    fn default() -> Self {
        Self {
            base_url: String::new(),
            api_key: String::new(),
            model: String::new(),
            dim: 1024,
            batch_size: 32,
            timeout_secs: 60,
        }
    }
}

impl EmbedConfig {
    pub fn is_ready(&self) -> bool {
        !self.base_url.trim().is_empty()
            && !self.api_key.trim().is_empty()
            && !self.model.trim().is_empty()
    }
}

/// 向量化错误。
#[derive(Debug)]
pub enum EmbedError {
    NotConfigured,
    Http(String),
    Auth(String),
    RateLimit(String),
    DimensionMismatch { expected: usize, actual: usize },
}

impl std::fmt::Display for EmbedError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotConfigured => write!(f, "Embedding 未配置（base_url/api_key/model）"),
            Self::Http(m) => write!(f, "Embedding HTTP 错误: {m}"),
            Self::Auth(m) => write!(f, "Embedding 认证失败: {m}"),
            Self::RateLimit(m) => write!(f, "Embedding 限流: {m}"),
            Self::DimensionMismatch { expected, actual } => {
                write!(f, "向量维度不匹配: 模型输出 {actual}D, 配置期望 {expected}D")
            }
        }
    }
}

/// 批量向量化，返回与输入等长的向量列表。
pub async fn embed_batch(cfg: &EmbedConfig, texts: &[String]) -> Result<Vec<Vec<f32>>, EmbedError> {
    if !cfg.is_ready() {
        return Err(EmbedError::NotConfigured);
    }
    if texts.is_empty() {
        return Ok(Vec::new());
    }

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(cfg.timeout_secs))
        .build()
        .map_err(|e| EmbedError::Http(e.to_string()))?;

    let mut results = Vec::with_capacity(texts.len());
    for batch in texts.chunks(cfg.batch_size) {
        let body = json!({
            "model": cfg.model,
            "input": batch,
        });
        let url = format!("{}/embeddings", cfg.base_url.trim_end_matches('/'));
        let response = client
            .post(&url)
            .bearer_auth(&cfg.api_key)
            .json(&body)
            .send()
            .await
            .map_err(|e| EmbedError::Http(e.to_string()))?;

        let status = response.status();
        let text = response
            .text()
            .await
            .map_err(|e| EmbedError::Http(e.to_string()))?;

        if status.is_success() {
            let value: serde_json::Value = serde_json::from_str(&text)
                .map_err(|e| EmbedError::Http(format!("JSON 解析失败: {e}")))?;
            let data = value["data"].as_array().ok_or_else(|| {
                EmbedError::Http("响应缺少 data 数组".to_string())
            })?;
            for item in data {
                let vec: Vec<f32> = item["embedding"]
                    .as_array()
                    .ok_or_else(|| EmbedError::Http("embedding 缺失".to_string()))?
                    .iter()
                    .filter_map(|v| v.as_f64().map(|f| f as f32))
                    .collect();
                if vec.len() != cfg.dim {
                    return Err(EmbedError::DimensionMismatch {
                        expected: cfg.dim,
                        actual: vec.len(),
                    });
                }
                results.push(l2_normalize(&vec));
            }
        } else if status == reqwest::StatusCode::UNAUTHORIZED {
            return Err(EmbedError::Auth(text));
        } else if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
            return Err(EmbedError::RateLimit(text));
        } else {
            return Err(EmbedError::Http(format!("HTTP {}: {}", status, text)));
        }
    }
    Ok(results)
}

/// 单条向量化。
pub async fn embed_one(cfg: &EmbedConfig, text: &str) -> Result<Vec<f32>, EmbedError> {
    let results = embed_batch(cfg, &[text.to_string()]).await?;
    results.into_iter().next().ok_or_else(|| EmbedError::Http("空响应".to_string()))
}

/// L2 归一化。
fn l2_normalize(vec: &[f32]) -> Vec<f32> {
    let norm: f32 = vec.iter().map(|v| v * v).sum::<f32>().sqrt();
    if norm == 0.0 || norm.is_nan() {
        return vec.to_vec();
    }
    vec.iter().map(|v| v / norm).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn not_configured_when_empty() {
        let cfg = EmbedConfig::default();
        assert!(!cfg.is_ready());
    }

    #[test]
    fn l2_normalizes() {
        let vec = vec![3.0, 4.0];
        let normalized = l2_normalize(&vec);
        let norm: f32 = normalized.iter().map(|v| v * v).sum::<f32>().sqrt();
        assert!((norm - 1.0).abs() < 1e-6);
    }
}

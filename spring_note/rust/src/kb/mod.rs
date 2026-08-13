//! 知识库模块 — Rust 重写 XiaoYu RAG（替代 Python sidecar）。
//!
//! 模块结构（与 sidecar/kb 对齐）：
//! - store:     SQLite 存储（files/chunks/cells/meta）
//! - scanner:   目录扫描 + 增量判重
//! - parser:    文件解析（md/txt/docx/pdf/xlsx）
//! - chunker:   结构化切块 + 滑动窗口
//! - embedder:  OpenAI 兼容 embedding 客户端
//! - retriever: 时间词解析 + 余弦 top-k + 来源多样性
//! - exact:     Excel 精确值检索
//! - generator: Prompt 组装 + 引用 + 脱敏
//! - kb:        Frb 对外 API（scan/index/ask/tree/files）

pub mod chunker;
pub mod embedder;
pub mod exact;
pub mod generator;
pub mod kb;
pub mod parser;
pub mod retriever;
pub mod scanner;
pub mod server;
pub mod store;
pub mod utils;

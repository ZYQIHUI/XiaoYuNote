"""XiaoYu 向量化层 — 批量向量化、断点续传、L2 归一化、幂等"""

from __future__ import annotations

import logging
import math
from typing import Optional

import numpy as np

from ..config import Config
from ..llm import LLMClient
from ..models import Chunk
from .store import Store

logger = logging.getLogger("kb.embedder")


def embed_and_store(
    docs_chunks: list[Chunk],
    cfg: Config,
    store: Store,
    llm: Optional[LLMClient] = None,
) -> dict[str, int]:
    """批量向量化并入库（r1 第 8 节）。

    流程：
    1. 先写 chunks 占位行（status='pending', embedding=NULL）
    2. 批量调用 Embedding API
    3. L2 归一化后更新 embedding + status='ok'
    4. 失败重试耗尽 → status='failed'

    Returns:
        统计字典 {ok, failed, skipped}
    """
    if not docs_chunks:
        return {"ok": 0, "failed": 0, "skipped": len(docs_chunks)}

    if llm is None:
        llm = LLMClient(cfg)

    stats = {"ok": 0, "failed": 0, "skipped": 0}
    batch_size = cfg.vector.batch_size
    dim = cfg.vector.dim

    # 0) 清理这些文件已有的旧 chunk（r1 P0.2 增量：文件变更后 seq 偏移会导致残留）
    seen_files: set[str] = set()
    for ch in docs_chunks:
        if ch.rel_path in seen_files:
            continue
        seen_files.add(ch.rel_path)
        store.clear_chunks(ch.rel_path)

    # 1) 写占位行
    file_ids = store.upsert_chunk_placeholders(docs_chunks)

    # 2) 分批向量化
    texts = [c.text for c in docs_chunks]
    total = len(texts)

    for i in range(0, total, batch_size):
        batch_texts = texts[i : i + batch_size]
        batch_indices = list(range(i, min(i + batch_size, total)))

        try:
            # 调用 API
            raw_vectors = llm.embed(batch_texts)

            # 首批维度校验 (r1 P2.14)
            if i == 0 and raw_vectors:
                actual_dim = len(raw_vectors[0])
                if actual_dim != dim:
                    logger.error(
                        f"向量维度不匹配: 模型输出 {actual_dim}D, 配置期望 {dim}D。"
                        f"请检查 [vector].dim 或执行 kb reset"
                    )
                    raise ValueError(f"维度不匹配: {actual_dim} != {dim}")

            # L2 归一化 (r1 P1.8)
            normalized = [_l2_normalize(v) for v in raw_vectors]

            # 更新库
            for j, idx in enumerate(batch_indices):
                store.update_chunk_embedding(docs_chunks[idx], normalized[j])
                docs_chunks[idx].embedding = normalized[j]
                docs_chunks[idx].status = "ok"
            stats["ok"] += len(batch_indices)

            logger.debug(f"向量化批次 [{i}:{i+len(batch_texts)}] 完成 ({len(batch_texts)} 条)")

        except Exception as e:
            logger.error(f"向量化批次 [{i}:{i+len(batch_texts)}] 失败: {e}")
            for idx in batch_indices:
                store.update_chunk_status(docs_chunks[idx], "failed")
                docs_chunks[idx].status = "failed"
            stats["failed"] += len(batch_indices)

    logger.info(f"向量化完成: ok={stats['ok']}, failed={stats['failed']}")
    return stats


def _l2_normalize(vec: list[float]) -> list[float]:
    """L2 归一化 (r1 P1.8)。"""
    arr = np.array(vec, dtype=np.float32)
    norm = np.linalg.norm(arr)
    if norm == 0 or np.isnan(norm):
        return vec
    return (arr / norm).tolist()

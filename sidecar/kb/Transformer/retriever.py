"""XiaoYu 检索层 — 查询理解、余弦 top-k、来源多样性、元数据过滤（r1 第 9 节）"""

from __future__ import annotations

import logging
from datetime import date
from typing import Optional

import numpy as np

from ..config import Config
from ..llm import LLMClient
from ..utils import parse_time_query
from ..QA.store import Store

logger = logging.getLogger("kb.retriever")


class Retriever:
    """检索器：时间词解析 → query 向量化 → 余弦 top-k → 来源多样性过滤。"""

    def __init__(self, cfg: Config, llm: Optional[LLMClient] = None) -> None:
        self._cfg = cfg
        self._llm = llm or LLMClient(cfg)

    def _get_store(self) -> Store:
        """创建（可被测试替换的）存储实例。"""
        return Store(self._cfg)

    def topk(
        self,
        query: str,
        k: Optional[int] = None,
        date_range: Optional[tuple[int, int]] = None,
        file_types: Optional[list[str]] = None,
        path_prefix: Optional[str] = None,
    ) -> list[dict]:
        """执行检索，返回 top-k chunks（含 rel_path）。

        Args:
            query: 用户问题。
            k: top-k（默认配置值）。
            date_range: (start_YYYYMMDD, end_YYYYMMDD)，可由 ask 流程先解析时间词得到。
            file_types: 过滤文件类型列表。
            path_prefix: 路径前缀（如 '小组/'）。
        """
        store = self._get_store()
        k = k or self._cfg.retrieval.top_k

        # 1) 时间词解析前置（r1 P1.5 / 9.0 节）
        if date_range is None:
            parsed = parse_time_query(query, date.today())
            if parsed:
                logger.info(f"时间词解析：{query} → {parsed}")
                date_range = parsed

        # 2) 从库中获取候选 chunks（带 SQL 过滤）
        include_null = self._cfg.retrieval.include_null_date
        candidates = store.get_all_chunks_for_retrieval(
            date_range=date_range,
            file_types=file_types,
            path_prefix=path_prefix,
            include_null_date=include_null,
        )

        if not candidates:
            logger.warning("检索结果为空（无匹配 filters 或库为空）")
            return []

        # 3) Query 向量化 + L2 归一化
        instruction = self._cfg.vector.query_instruction
        query_text = (instruction + query) if instruction else query
        query_vec = np.array(self._llm.embed_one(query_text), dtype=np.float32)
        query_norm = query_vec / (np.linalg.norm(query_vec) or 1e-9)

        # 4) 构建矩阵算余弦相似度
        embeddings = [np.frombuffer(c["embedding"], dtype=np.float32) for c in candidates]
        matrix = np.vstack(embeddings)  # (N, dim)
        scores = matrix @ query_norm    # 已归一化 ⇒ 余弦

        # 5) top-k + 来源多样性约束（r1 P1.6 / 9.1 节）
        max_per_file = self._cfg.retrieval.max_per_file
        selected: list[dict] = []
        file_counts: dict[int, int] = {}  # file_id → count

        order = np.argsort(-scores)
        for idx in order:
            if len(selected) >= k:
                break
            cand = candidates[idx]
            fid = cand["file_id"]
            cnt = file_counts.get(fid, 0)
            if cnt >= max_per_file:
                continue
            file_counts[fid] = cnt + 1
            cand["score"] = float(scores[idx])
            selected.append(cand)

        logger.info(f"检索完成：top-k={len(selected)}，候选总数={len(candidates)}")
        return selected

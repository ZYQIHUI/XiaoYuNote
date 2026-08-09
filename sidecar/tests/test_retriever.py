"""检索层单元测试 — 余弦排序、top-k、日期过滤、来源多样性"""

import pytest
import numpy as np
from unittest.mock import MagicMock, patch
from kb.config import Config, RetrievalConfig


def _mock_embed(MockLLM) -> None:
    """让 mock LLM 返回 1024 维归一化向量（与配置 dim 一致）。"""
    vec = np.random.randn(1024).astype(np.float32)
    vec = vec / np.linalg.norm(vec)
    MockLLM.return_value.embed_one.return_value = vec.tolist()


class TestRetriever:
    """检索核心逻辑验证（构造小库假数据）。"""

    def _mock_store_with_data(self, date_range=None):
        """构造带假数据的 mock store。"""
        store = MagicMock()
        # 模拟返回 5 个 chunk
        fake_chunks = []
        for i in range(5):
            # 构造不同维度的向量
            vec = np.random.randn(1024).astype(np.float32)
            vec = vec / np.linalg.norm(vec)
            import struct
            blob = struct.pack(f"{len(vec)}f", *vec)

            fake_chunks.append({
                "id": i + 1,
                "file_id": (i // 2) + 1,  # 每 2 个 chunk 同一个 file_id
                "seq": i,
                "text": f"测试文本 {i} 内容...",
                "embedding": blob,
                "date": 20260720 + i,
                "file_type": ["excel", "md", "pdf", "excel", "md"][i],
                "sheet_name": None,
                "row_start": None,
                "row_end": None,
                "heading": None,
                "rel_path": f"个人/2026-7-{20+i}/file{i}.ext",
            })

        store.get_all_chunks_for_retrieval.return_value = fake_chunks
        return store

    @patch("kb.Transformer.retriever.Store")
    @patch("kb.Transformer.retriever.LLMClient")
    def test_topk_returns_k_results(self, MockLLM, MockStore):
        """top-k 返回不超过 k 条结果。"""
        from kb.Transformer.retriever import Retriever

        cfg = Config()
        cfg.retrieval = RetrievalConfig(top_k=3, max_per_file=2)
        retriever = Retriever(cfg)
        _mock_embed(MockLLM)

        with patch.object(retriever, "_get_store") as mock_get_store:
            mock_get_store.return_value = self._mock_store_with_data()

            results = retriever.topk("测试问题")
            assert len(results) <= 3

    @patch("kb.Transformer.retriever.Store")
    @patch("kb.Transformer.retriever.LLMClient")
    def test_date_filter_applied(self, MockLLM, MockStore):
        """日期范围过滤生效。"""
        from kb.Transformer.retriever import Retriever

        cfg = Config()
        cfg.retrieval = RetrievalConfig(top_k=10)
        retriever = Retriever(cfg)
        _mock_embed(MockLLM)

        mock_store = self._mock_store_with_data()
        # 验证 store 调用时传入了正确的 date_range 参数
        with patch.object(retriever, "_get_store", return_value=mock_store):
            results = retriever.topk(
                "测试问题",
                date_range=(20260721, 20260723),
            )
            mock_store.get_all_chunks_for_retrieval.assert_called_once()
            call_kwargs = mock_store.get_all_chunks_for_retrieval.call_args
            assert call_kwargs.kwargs.get("date_range") == (20260721, 20260723)

    @patch("kb.Transformer.retriever.Store")
    @patch("kb.Transformer.retriever.LLMClient")
    def test_diversity_max_per_file(self, MockLLM, MockStore):
        """来源多样性：每个 file_id 不超过 max_per_file 条。"""
        from kb.Transformer.retriever import Retriever

        cfg = Config()
        cfg.retrieval = RetrievalConfig(top_k=10, max_per_file=2)
        retriever = Retriever(cfg)
        _mock_embed(MockLLM)

        with patch.object(retriever, "_get_store") as mock_get_store:
            mock_get_store.return_value = self._mock_store_with_data()
            results = retriever.topk("测试问题")

            # 统计每个 file_id 出现次数
            file_counts: dict[int, int] = {}
            for r in results:
                fid = r["file_id"]
                file_counts[fid] = file_counts.get(fid, 0) + 1

            for fid, cnt in file_counts.items():
                assert cnt <= 2, f"file_id={fid} 出现 {cnt} 次 > max_per_file=2"

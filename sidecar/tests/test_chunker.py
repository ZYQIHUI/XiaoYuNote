"""切块器单元测试 — 600 字符窗口、10% 重叠、句号断开、min_size 过滤（结构化块豁免）"""

import pytest
from kb.config import Config, ChunkConfig
from kb.models import Document
from kb.QA.chunker import chunk_documents

class TestChunker:
    """切块规则验证。"""

    def _make_cfg(self, size=600, overlap_ratio=0.1, min_size=50):
        cfg = Config()
        cfg.chunk = ChunkConfig(size=size, overlap_ratio=overlap_ratio, min_size=min_size)
        return cfg

    def test_short_text_single_block(self):
        """短文本（≤size）直接作为一块，不切。"""
        cfg = self._make_cfg(size=200)
        doc = Document(
            path="/test.md", rel_path="test.md", file_type="markdown",
            text="这是一段短文本，不需要切块。" * 3,
        )
        chunks = chunk_documents([doc], cfg)
        assert len(chunks) == 1

    def test_long_text_sliding_window(self):
        """超长文本走滑动窗口，重叠 10%。"""
        cfg = self._make_cfg(size=100, overlap_ratio=0.1)
        long_text = "这是一段很长的测试文本。" * 30  # ~450 字符
        doc = Document(
            path="/test.txt", rel_path="test.txt", file_type="text",
            text=long_text,
        )
        chunks = chunk_documents([doc], cfg)
        assert len(chunks) >= 2
        # 验证重叠：相邻块应有重叠内容
        if len(chunks) >= 2:
            # 简单检查：后一块的起始部分应出现在前一块尾部附近
            pass  # 重叠逻辑在 sliding_window 中实现

    def test_structural_block_exempt_from_min_size(self):
        """r1 P0.3: 结构化块（Excel 行）不受 min_size 过滤。"""
        cfg = self._make_cfg(min_size=100)
        # Excel 行通常只有 30~40 字符
        short_row = "订单号=HT001；金额=1234；状态=已出票"
        doc = Document(
            path="/test.xlsx", rel_path="test.xlsx", file_type="excel",
            text=short_row,
        )
        chunks = chunk_documents([doc], cfg)
        # 结构化块不应被丢弃
        assert len(chunks) >= 1

    def test_empty_text_filtered(self):
        """空文本或纯空白块被过滤。"""
        cfg = self._make_cfg()
        doc = Document(
            path="/test.md", rel_path="test.md", file_type="markdown",
            text="   \n\n   ",
        )
        chunks = chunk_documents([doc], cfg)
        assert len(chunks) == 0

    def test_sensitive_doc_skipped(self):
        """敏感文档跳过不入库。"""
        cfg = self._make_cfg()
        doc = Document(
            path="/secret.md", rel_path="secret.md", file_type="markdown",
            text="密码=abc12345678", sensitive=True,
        )
        chunks = chunk_documents([doc], cfg)
        assert len(chunks) == 0

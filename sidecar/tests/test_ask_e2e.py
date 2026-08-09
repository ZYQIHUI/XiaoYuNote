"""问答链路端到端测试 — 检索 → 生成全流程（embed 与 chat 均 mock，库为真实 SQLite）

覆盖：真实提问 → top-k 检索 → 带引用回答；时间词自动解析；无结果场景。
"""

import numpy as np
import pytest
from datetime import datetime
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from kb.config import Config
from kb.QA.store import Store
from kb.models import Chunk, FileRecord
from kb.Transformer.retriever import Retriever
from kb.Transformer.generator import Generator


class FakeEmbedLLM:
    """模拟 embedding：embed_one 返回固定 1024 维归一化向量。"""

    def __init__(self, dim: int = 1024, seed: int = 7):
        self.dim = dim
        self.rng = np.random.default_rng(seed)

    def embed_one(self, text: str) -> list[float]:
        v = self.rng.standard_normal(self.dim).astype(np.float32)
        return (v / np.linalg.norm(v)).tolist()


# 与拼房/对账场景相关的样例数据（含时间词验证所需的上周日期）
SEED_ROWS = [
    ("个人/2026-7-21/对账清单.xlsx",
     "拼房对账单据 D20260721002 金额 186.50 状态 已对账；单据 D20260721003 金额 186.50 状态 差异",
     20260721),
    ("小组/2026-7-28/今日总结.md",
     "风险提示：拼房场景的对账数据量较大，需要重点核对结算金额与分摊比例",
     20260728),
    ("个人/2026-7-15/日报.md",
     "预订模块功能测试完成，输出 12 条用例，发现缺陷 #1023",
     20260715),
]


def _seed_store(store: Store) -> None:
    """直接写入文件记录 + chunk（随机向量），构造可检索的库。"""
    rng = np.random.default_rng(1)
    file_ids: dict[str, int] = {}
    chunks: list[Chunk] = []
    for i, (rel, text, date) in enumerate(SEED_ROWS):
        if rel not in file_ids:
            rec = FileRecord(
                rel_path=rel, file_hash="h", size_bytes=10, mtime_ns=1,
                date=date, date_source="dirname",
                parsed_at=datetime.now().isoformat(), status="ok",
            )
            file_ids[rel] = store.upsert_file(rec)
        ch = Chunk(file_id=file_ids[rel], seq=0, text=text, date=date,
                   file_type="md", rel_path=rel)
        chunks.append(ch)

    store.upsert_chunk_placeholders(chunks)
    for ch in chunks:
        v = rng.standard_normal(1024).astype(np.float32)
        v = v / np.linalg.norm(v)
        store.update_chunk_embedding(ch, v.tolist())


@pytest.fixture
def qa_project(tmp_path):
    """真实 SQLite 小库 + 配置。"""
    cfg = Config(root_dir=tmp_path)
    cfg.data.sources = ["个人"]
    store = Store(cfg)
    _seed_store(store)
    return SimpleNamespace(cfg=cfg, store=store, root=tmp_path)


class TestAskE2E:
    """问一句 → 检索 → 生成带引用回答。"""

    def test_ask_full_flow(self, qa_project):
        """真实提问：返回非空回答 + 结构化引用 + prompt 含检索资料。"""
        fake_chat = MagicMock()
        fake_chat.chat.return_value = (
            "拼房场景的对账差异主要有两类：\n"
            "1. 结算金额差异（单据 D20260721003 状态为差异）\n"
            "2. 数据量大导致的核对遗漏"
        )
        retriever = Retriever(qa_project.cfg, llm=FakeEmbedLLM())
        generator = Generator(qa_project.cfg, llm=fake_chat)

        query = "拼房场景有哪些对账差异"
        chunks = retriever.topk(query)
        assert len(chunks) > 0

        answer, refs = generator.generate(
            query, chunks, profile_text="【个人画像】- 角色：测试实习生",
        )
        assert "拼房场景" in answer
        assert refs, "应返回结构化引用"
        assert all("source" in r for r in refs)
        assert any("对账清单.xlsx" in r["source"] for r in refs)

        # chat 收到的 prompt 必须包含检索资料与画像
        prompt = fake_chat.chat.call_args[0][0][0]["content"]
        assert "<retrieved_docs>" in prompt
        assert "个人画像" in prompt
        assert "拼房" in prompt

    def test_ask_empty_knowledge_base(self, qa_project):
        """知识库无相关内容：refs 为空，仍返回回答（LLM 明示未找到）。"""
        fake_chat = MagicMock()
        fake_chat.chat.return_value = "知识库中未找到相关内容"
        generator = Generator(qa_project.cfg, llm=fake_chat)

        answer, refs = generator.generate("随便问问", [], profile_text="")
        assert answer == "知识库中未找到相关内容"
        assert refs == []

    def test_time_word_auto_date_filter(self, qa_project):
        """时间词自动解析：'上周' 提问 → store 收到 date_range 过滤。"""
        retriever = Retriever(qa_project.cfg, llm=FakeEmbedLLM())
        mock_store = MagicMock()
        mock_store.get_all_chunks_for_retrieval.return_value = []

        with patch.object(retriever, "_get_store", return_value=mock_store):
            retriever.topk("上周拼房场景的对账问题是什么")

        kwargs = mock_store.get_all_chunks_for_retrieval.call_args.kwargs
        assert kwargs["date_range"] is not None, "时间词未转成 date_range"
        start, end = kwargs["date_range"]
        assert start < end

"""生成层单元测试 — 上下文预算、Prompt 组装、引用格式化、输出脱敏（chat 用 mock）"""

from unittest.mock import MagicMock

from kb.config import Config
from kb.Transformer.generator import (
    Generator,
    _apply_context_budget,
    _build_references,
)


def _chunk(rel: str, text: str, score: float, date: int = 20260720,
           row_start: int | None = None, row_end: int | None = None,
           heading: str | None = None) -> dict:
    return {
        "rel_path": rel, "text": text, "score": score, "date": date,
        "row_start": row_start, "row_end": row_end, "heading": heading,
        "file_type": "md",
    }


class TestContextBudget:
    """上下文预算：超限时从最低分块开始丢弃。"""

    def test_within_budget_keeps_all(self):
        cfg = Config()
        cfg.retrieval.max_context_chars = 1000
        chunks = [_chunk("a.md", "x" * 100, 0.8), _chunk("b.md", "y" * 100, 0.5)]
        assert len(_apply_context_budget(chunks, 1000)) == 2

    def test_over_budget_drops_lowest_score(self):
        chunks = [
            _chunk("high.md", "h" * 60, 0.9),
            _chunk("low.md", "l" * 60, 0.1),   # 最低分，应被丢弃
            _chunk("mid.md", "m" * 60, 0.5),
        ]
        kept = _apply_context_budget(chunks, 120)   # 只能容纳 2 块
        assert len(kept) == 2
        sources = {c["rel_path"] for c in kept}
        assert "low.md" not in sources             # 最低分被裁掉
        assert "high.md" in sources


class TestGeneratorPrompt:
    """Prompt 组装：个人画像注入、<retrieved_docs> 分隔符、问题与要求。"""

    def _generate_with_capture(self, chunks, profile_text="", query="拼房对账问题"):
        cfg = Config()
        fake_chat = MagicMock()
        fake_chat.chat.return_value = "基于检索资料的回答"
        gen = Generator(cfg, llm=fake_chat)
        answer, refs = gen.generate(query, chunks, profile_text=profile_text)
        prompt = fake_chat.chat.call_args[0][0][0]["content"]
        return answer, refs, prompt

    def test_prompt_includes_profile_and_delimiter(self):
        _, _, prompt = self._generate_with_capture(
            [_chunk("个人/2026-7-21/对账清单.xlsx", "拼房对账金额 186.50", 0.9)],
            profile_text="【个人画像】- 角色：测试实习生",
        )
        assert "【个人画像】" in prompt
        assert "- 角色：测试实习生" in prompt
        assert "<retrieved_docs>" in prompt
        assert "</retrieved_docs>" in prompt
        assert "拼房对账问题" in prompt
        # 检索资料带来源与相关度
        assert "对账清单.xlsx" in prompt
        assert "相关度" in prompt

    def test_empty_chunks_no_references(self):
        _, refs, prompt = self._generate_with_capture([])
        assert refs == []
        assert "【检索到的资料（按相关度排序）】" in prompt

    def test_chat_never_sees_failed_content(self):
        """生成必须基于检索结果（mock chat 验证只调用一次并返回回答）。"""
        cfg = Config()
        fake_chat = MagicMock()
        fake_chat.chat.return_value = "回答"
        gen = Generator(cfg, llm=fake_chat)
        answer, _ = gen.generate("q", [_chunk("a.md", "内容", 0.7)])
        assert answer == "回答"
        fake_chat.chat.assert_called_once()


class TestReferences:
    """结构化引用：行号 / 标题元数据映射。"""

    def test_rows_reference(self):
        refs = _build_references([
            _chunk("a.xlsx", "t", 0.8, row_start=2, row_end=6),
        ])
        assert refs[0]["source"] == "a.xlsx"
        assert refs[0]["rows"] == "2~6"
        assert "heading" not in refs[0]

    def test_heading_reference(self):
        refs = _build_references([
            _chunk("b.md", "t", 0.8, heading="风险提示"),
        ])
        assert refs[0]["heading"] == "风险提示"
        assert "rows" not in refs[0]

    def test_date_included(self):
        refs = _build_references([_chunk("c.md", "t", 0.8, date=20260728)])
        assert refs[0]["date"] == 20260728


class TestOutputSecurity:
    """第三道防线：输出后置脱敏扫描。"""

    def test_answer_desensitized(self):
        cfg = Config()
        fake_chat = MagicMock()
        fake_chat.chat.return_value = "登录密码：abc123456xyz，请妥善保管"
        gen = Generator(cfg, llm=fake_chat)
        answer, _ = gen.generate("q", [_chunk("a.md", "t", 0.8)])
        assert "abc123456xyz" not in answer
        assert "[已脱敏]" in answer

    def test_clean_answer_untouched(self):
        cfg = Config()
        fake_chat = MagicMock()
        fake_chat.chat.return_value = "正常回答内容"
        gen = Generator(cfg, llm=fake_chat)
        answer, _ = gen.generate("q", [_chunk("a.md", "t", 0.8)])
        assert answer == "正常回答内容"

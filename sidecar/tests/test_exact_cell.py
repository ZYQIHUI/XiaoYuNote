"""M2 表格感知问答测试 — 精确值命中单号/金额 + 单元格级引用。

对样例 `对账清单.xlsx`：提问单号/金额应精确命中 cells 索引并返回
`文件!Sheet 单元格` 形式的引用，弥补向量 top-k 对精确值检索弱的问题。
"""

import numpy as np
import pytest
from pathlib import Path
from types import SimpleNamespace

from kb.config import Config
from kb.QA.store import Store
from kb.QA.parsers.excel_parser import extract_cells
from kb.QA.exact import search_exact, extract_query_tokens


def _build_duizhang(tmp_path: Path) -> Path:
    """构造对账清单.xlsx（表头 + 2 行数据，与真实场景同构）。"""
    from openpyxl import Workbook

    f = tmp_path / "个人" / "2026-7-21" / "对账清单.xlsx"
    f.parent.mkdir(parents=True, exist_ok=True)
    wb = Workbook()
    ws = wb.active
    ws.title = "对账"
    ws.append(["单号", "金额", "状态"])
    ws.append(["D20260721002", "186.50", "已对账"])
    ws.append(["D20260721003", "186.50", "差异"])
    wb.save(str(f))
    return f


class TestTokenExtraction:
    def test_single_number(self):
        assert extract_query_tokens("D20260721002 金额多少")[0] == ["D20260721002"]

    def test_money_and_id(self):
        exact, _ = extract_query_tokens("上月对账清单 D20260721003 金额 186.50")
        assert "D20260721003" in exact
        assert "186.50" in exact

    def test_chinese_token_for_like(self):
        _, like = extract_query_tokens("状态是已对账的单据")
        assert "已对账" in like


class TestExactSearch:
    @pytest.fixture
    def indexed(self, tmp_path):
        """真实 SQLite + cells 精确值索引。"""
        f = _build_duizhang(tmp_path)
        cfg = Config(root_dir=tmp_path)
        cfg.store.path = "kb.sqlite3"
        store = Store(cfg)
        cells = extract_cells(f, cfg)
        assert cells, "应提取到非空单元格"
        store.replace_cells("个人/2026-7-21/对账清单.xlsx", cells)
        return SimpleNamespace(store=store, cfg=cfg)

    def test_exact_hit_single_number(self, indexed):
        hits = search_exact(indexed.store, "D20260721002")
        assert hits
        hit = hits[0]
        assert hit["value"] == "D20260721002"
        assert hit["header"] == "单号"
        assert hit["row"] == 2
        assert hit["col_letter"] == "A"
        assert hit["ref"] == "个人/2026-7-21/对账清单.xlsx!对账 A2"

    def test_exact_hit_amount_with_header(self, indexed):
        hits = search_exact(indexed.store, "金额 186.50")
        assert hits
        assert any(h["value"] == "186.50" and h["header"] == "金额" for h in hits)

    def test_like_hit_status(self, indexed):
        hits = search_exact(indexed.store, "已对账的单据")
        assert hits
        assert any(h["header"] == "状态" and h["value"] == "已对账" for h in hits)

    def test_exact_prefers_exact_over_like(self, indexed):
        """同一单元格同时被精确与 LIKE 命中时只出现一次（去重）。"""
        hits = search_exact(indexed.store, "D20260721002 已对账", top_n=20)
        keys = [(h["row"], h["col"]) for h in hits]
        assert len(keys) == len(set(keys))

    def test_no_match_returns_empty(self, indexed):
        assert search_exact(indexed.store, "完全不存在的内容XYZ") == []

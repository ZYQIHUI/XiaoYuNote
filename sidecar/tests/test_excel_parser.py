"""Excel 解析器单元测试 — 表头识别、行分组合块、合并单元格前向填充、.xls 兼容"""

import pytest
from pathlib import Path
import tempfile
from unittest.mock import patch

# 注意：这些测试需要 openpyxl 和 pandas 安装


class TestExcelParser:
    """Excel 行分组合块核心逻辑验证。"""

    @pytest.fixture
    def sample_xlsx(self, tmp_path):
        """创建一个示例 xlsx 文件用于测试。"""
        try:
            from openpyxl import Workbook
            wb = Workbook()
            ws = wb.active
            ws.title = "Sheet1"

            # 表头
            ws.append(["订单号", "产品", "金额", "状态", "成本中心"])
            # 数据行
            ws.append(["HT260721001", "机票", "1234.00", "已出票", "客户成功事业部"])
            ws.append(["HT260721002", "火车票", "567.00", "已出票", "客户成功事业部"])
            ws.append(["HT260721003", "酒店", "2000.00", "待确认", "客户成功事业部"])
            # 空行
            ws.append([])
            ws.append(["HT260722004", "餐饮", "150.00", "已出票", "财务部"])

            f = tmp_path / "test.xlsx"
            wb.save(str(f))
            return f
        except ImportError:
            pytest.skip("openpyxl 未安装")

    def test_header_detection(self, sample_xlsx):
        """表头识别：非空单元格最多的行视为表头。"""
        from kb.QA.parsers.excel_parser import _detect_header
        rows_data = [
            ["订单号", "产品", "金额", "状态", "成本中心"],
            ["HT260721001", "机票", "1234.00", "已出票", "客户成功事业部"],
        ]
        headers, data = _detect_header(rows_data)
        assert headers is not None
        assert len(headers) == 5
        assert "订单号" in headers

    def test_forward_fill(self):
        """合并单元格前向填充：空值取上方最近非空值。"""
        from kb.QA.parsers.excel_parser import _forward_fill
        rows = [
            ["A组", "张三", "100"],
            [""   , "李四", "200"],     # A 组应向下填充
            ["B组", "王五", "300"],
            [""   , ""   , "400"],      # B 组应向下填充
        ]
        filled = _forward_fill(rows)
        assert filled[1][0] == "A组"
        assert filled[3][0] == "B组"

    def test_row_group_chunk_size_limit(self):
        """行分组合块：相邻行拼到接近 size 上限为止。"""
        from kb.QA.parsers.excel_parser import _row_group_chunk
        from dataclasses import dataclass
        from types import SimpleNamespace

        cfg = SimpleNamespace(chunk=SimpleNamespace(size=80))
        headers = ["订单号", "金额"]
        rows_data = [
            ["HT001", "100"],
            ["HT002", "200"],
            ["HT003", "300"],
            ["HT004", "400"],
        ]

        docs = _row_group_chunk(
            headers, rows_data,
            rel_path="test.xlsx",
            file_path=Path("test.xlsx"),
            date=20260721, date_source="filename",
            sheet_name="Sheet1", cfg=cfg, sensitive=False,
        )
        assert len(docs) >= 1
        # 验证每个块的 text 不超过 size
        for doc in docs:
            assert len(doc.text) <= cfg.chunk.size + 20  # 少量容差

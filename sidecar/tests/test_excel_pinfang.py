"""拼房/多次结算场景 Excel 解析测试 — 表头、合并单元格前向填充、日期、行号元数据"""

import pytest
from pathlib import Path
from types import SimpleNamespace

from kb.config import Config


class TestExcelPinfang:
    """用拼房大表（合并单元格 + 多日多房费）验证 parse_excel 全流程。"""

    @pytest.fixture
    def pinfang_xlsx(self, tmp_path):
        """构造拼房大表：房间号合并单元格（A301 跨 2 行），多日多次结算。"""
        try:
            from openpyxl import Workbook
            from openpyxl.styles import Alignment

            wb = Workbook()
            ws = wb.active
            ws.title = "拼房明细"
            ws.append(["房间号", "入住人", "日期", "房费", "分摊比例", "结算状态"])
            # A301 合并两行（同房多人），模拟合并单元格
            ws.append(["A301", "张三", "2026-07-20", "600.00", 0.5, "已结算"])
            ws.append([None, "李四", "2026-07-20", "600.00", 0.5, "未结算"])
            ws.append(["B205", "王五", "2026-07-23", "450.00", 1.0, "已结算"])
            ws.merge_cells("A2:A3")

            d = tmp_path / "个人" / "2026-7-23"
            d.mkdir(parents=True)
            f = d / "拼房大表.xlsx"
            wb.save(str(f))
            return f
        except ImportError:
            pytest.skip("openpyxl 未安装")

    def test_parse_pinfang(self, pinfang_xlsx, tmp_path):
        """完整解析：单块输出、行号元数据、日期来源、合并单元格填充。"""
        from kb.QA.parsers.excel_parser import parse_excel

        cfg = Config(root_dir=tmp_path)
        docs = parse_excel(pinfang_xlsx, cfg)

        # 小表应整体作为一块
        assert len(docs) == 1
        doc = docs[0]

        # 元数据
        assert doc.file_type == "excel"
        assert doc.sheet_name == "拼房明细"
        assert doc.date == 20260723
        assert doc.date_source == "dirname"   # 目录名 2026-7-23
        assert doc.row_start == 2             # Excel 行号从 2 开始（1 是表头）
        assert doc.row_end == 4
        assert doc.sensitive is False

        # 行文本格式：表头=值
        assert "房间号=A301；入住人=张三" in doc.text
        assert "结算状态=已结算" in doc.text

    def test_merged_cell_forward_fill(self, pinfang_xlsx, tmp_path):
        """合并单元格前向填充：李四所在行应继承 A301。"""
        from kb.QA.parsers.excel_parser import parse_excel

        cfg = Config(root_dir=tmp_path)
        docs = parse_excel(pinfang_xlsx, cfg)
        assert len(docs) == 1
        text = docs[0].text

        # 合并单元格 A2:A3 → 李四行房间号被填充为 A301
        assert "房间号=A301；入住人=李四" in text
        # 独立行 B205 不受影响
        assert "房间号=B205；入住人=王五" in text

    def test_multiple_settlement_rows_kept(self, pinfang_xlsx, tmp_path):
        """多次结算行完整保留（已结算/未结算状态并存）。"""
        from kb.QA.parsers.excel_parser import parse_excel

        cfg = Config(root_dir=tmp_path)
        docs = parse_excel(pinfang_xlsx, cfg)
        text = docs[0].text
        assert "已结算" in text
        assert "未结算" in text
        # 3 条数据行全部在块内
        assert text.count("入住人=") == 3

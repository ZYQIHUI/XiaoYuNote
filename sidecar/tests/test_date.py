"""日期提取单元测试（r1 6.6 节）"""

import pytest
from pathlib import Path
from kb.utils import extract_date_from_path, extract_date_from_content, _normalize_date


class TestDateExtraction:
    """目录名 / 文件名 / 内容首行 / mtime 四种提取与归一化。"""

    def test_dirname_extraction(self):
        """优先级1：祖先目录名提取日期。"""
        p = Path("/data/个人/2026-7-15/file.md")
        d, src = extract_date_from_path(p)
        assert d == 20260715
        assert src == "dirname"

    def test_filename_extraction(self):
        """优先级2：文件名提取日期。"""
        p = Path("/data/清单2026-07-2116_31_38.xlsx")
        d, src = extract_date_from_path(p)
        assert d == 20260721
        assert src == "filename"

    def test_content_first_line(self):
        """优先级3：内容首行提取日期。"""
        lines = ["2026-07-22", "", "正文内容..."]
        d, src = extract_date_from_content(lines)
        assert d == 20260722
        assert src == "content"

    def test_normalize_various_formats(self):
        """各种日期格式归一化为 YYYYMMDD 整数。"""
        assert _normalize_date("2026-7-15") == 20260715
        assert _normalize_date("2026年7月15日") == 20260715
        assert _normalize_date("2026/07/15") == 20260715
        assert _normalize_date("2026.7.15") == 20260715

    def test_no_date_fallback(self):
        """无法提取时返回 None + 'none'。"""
        p = Path("/data/random_folder/nodate.txt")
        # 模拟无日期目录和文件名的情况
        d, src = extract_date_from_path(p)
        # mtime 兜底，至少不是 none
        assert src in ("mtime", "none")

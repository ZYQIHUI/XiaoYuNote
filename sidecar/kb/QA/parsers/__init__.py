"""解析器注册表 — 按扩展名路由到对应解析器"""

from __future__ import annotations

from pathlib import Path
from typing import Callable

from ...config import Config
from ...models import Document

# 解析器类型签名
Parser = Callable[[Path, Config], list[Document]]

# 注册表（6.1 节）
PARSERS: dict[str, str] = {
    ".xlsx": "excel_parser.parse_excel",
    ".xls": "excel_parser.parse_excel",
    ".md": "markdown_parser.parse_markdown",
    ".txt": "text_parser.parse_text",
    ".docx": "docx_parser.parse_docx",
    ".pdf": "pdf_parser.parse_pdf",
}


def get_parser(ext: str) -> Parser | None:
    """根据扩展名返回解析器函数，未注册则返回 None。"""
    import importlib

    module_path = PARSERS.get(ext.lower())
    if not module_path:
        return None
    mod_name, func_name = module_path.rsplit(".", 1)
    try:
        # 延迟导入，避免未安装的依赖导致启动失败
        mod = importlib.import_module(f".{mod_name}", package=__package__)
        return getattr(mod, func_name)
    except ImportError:
        return None

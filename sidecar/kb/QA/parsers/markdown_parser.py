"""Markdown 解析器 — 按二级标题切块（r1 6.3 节）"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Optional

from ...config import Config
from ...models import Document
from ...utils import extract_date_from_path, desensitize, is_sensitive_file

logger = logging.getLogger("kb.parsers.md")


def parse_markdown(file_path: Path, cfg: Config) -> list[Document]:
    """解析 Markdown 文件，按 ## 二级标题切块。"""
    docs: list[Document] = []
    rel_path = file_path.relative_to(cfg.root_dir).as_posix()
    date, date_source = extract_date_from_path(file_path)

    text = file_path.read_text(encoding="utf-8", errors="replace")

    # 凭据脱敏
    clean_text, desens_count = desensitize(text)
    sensitive = is_sensitive_file(desens_count, rel_path)
    if sensitive and cfg.security.skip_sensitive_files:
        logger.warning(f"敏感文件跳过: {rel_path}")
        return []

    # 按 ## 二级标题分割
    import re
    sections = re.split(r"\n(?=## )", clean_text)

    for section in sections:
        section = section.strip()
        if not section or len(section) < cfg.chunk.min_size:
            continue

        # 提取二级标题作为 heading
        heading_match = re.match(r"^(## .+?)(?:\n|$)", section)
        heading = None
        if heading_match:
            heading = heading_match.group(1).strip("# ").strip()

        docs.append(Document(
            path=str(file_path),
            rel_path=rel_path,
            file_type="markdown",
            date=date,
            date_source=date_source,
            heading=heading,
            text=section,
            sensitive=sensitive,
        ))

    return docs if docs else [Document(
        path=str(file_path), rel_path=rel_path, file_type="markdown",
        date=date, date_source=date_source, text=clean_text, sensitive=sensitive,
    )]

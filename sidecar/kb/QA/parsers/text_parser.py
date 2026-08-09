"""文本 / OCR 日报解析器 — 首行日期提取 + 段落切块（r1 6.3 节）"""

from __future__ import annotations

import logging
from pathlib import Path

from ...config import Config
from ...models import Document
from ...utils import extract_date_from_path, extract_date_from_content, desensitize, is_sensitive_file

logger = logging.getLogger("kb.parsers.text")


def parse_text(file_path: Path, cfg: Config) -> list[Document]:
    """解析纯文本文件（含 OCR 日报 txt）。"""
    docs: list[Document] = []
    rel_path = file_path.relative_to(cfg.root_dir).as_posix()

    text = file_path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()

    # 日期提取（优先级 3：内容首行）
    date, date_source = extract_date_from_path(file_path)
    if date_source in ("none", "mtime"):
        content_date, content_src = extract_date_from_content(lines[:3])
        if content_date:
            date = content_date
            date_source = content_src

    # 凭据脱敏
    clean_text, desens_count = desensitize(text)
    sensitive = is_sensitive_file(desens_count, rel_path)
    if sensitive and cfg.security.skip_sensitive_files:
        logger.warning(f"敏感文件跳过: {rel_path}")
        return []

    # 按段落（空行分隔）切块
    paragraphs = clean_text.split("\n\n")
    for para in paragraphs:
        para = para.strip()
        if not para or len(para) < cfg.chunk.min_size:
            continue
        docs.append(Document(
            path=str(file_path), rel_path=rel_path, file_type="text",
            date=date, date_source=date_source,
            text=para, sensitive=sensitive,
        ))

    return docs if docs else [Document(
        path=str(file_path), rel_path=rel_path, file_type="text",
        date=date, date_source=date_source, text=text, sensitive=sensitive,
    )]

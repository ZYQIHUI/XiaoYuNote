"""PDF 解析器 — pymupdf 文本层提取（r1 6.5 节）"""

from __future__ import annotations

import logging
from pathlib import Path

from ...config import Config
from ...models import Document
from ...utils import extract_date_from_path, desensitize, is_sensitive_file

logger = logging.getLogger("kb.parsers.pdf")

# 扫描件判定阈值：全文提取字符数低于此值视为无文本层的扫描件
SCAN_THRESHOLD = 50


def parse_pdf(file_path: Path, cfg: Config) -> list[Document]:
    """解析 PDF 文件（仅文本层），扫描件跳过并标记 no_text。"""
    docs: list[Document] = []
    rel_path = file_path.relative_to(cfg.root_dir).as_posix()
    date, date_source = extract_date_from_path(file_path)

    try:
        import fitz  # pymupdf
        doc = fitz.open(str(file_path))
    except Exception as e:
        logger.error(f"PDF 解析失败: {file_path} — {e}")
        return []

    # 提取全部文本
    full_text = ""
    for page in doc:
        text = page.get_text()
        if text:
            full_text += text + "\n"
    doc.close()

    # 扫描件检测
    clean_text = "".join(full_text.split())
    if len(clean_text) < SCAN_THRESHOLD:
        logger.info(f"扫描件/无文本层，跳过: {rel_path} (字符数={len(clean_text)})")
        return [Document(
            path=str(file_path), rel_path=rel_path, file_type="pdf",
            date=date, date_source=date_source,
            text="", sensitive=False,
        )]  # 返回空 Document 以便记录 status='no_text'

    # 凭据脱敏
    desensitized, desens_count = desensitize(full_text)
    sensitive = is_sensitive_file(desens_count, rel_path)
    if sensitive and cfg.security.skip_sensitive_files:
        logger.warning(f"敏感文件跳过: {rel_path}")
        return []

    # 按页切块（每页一个 Document）
    doc_refit = fitz.open(str(file_path))
    for page_num, page in enumerate(doc_refit):
        page_text = page.get_text().strip()
        if not page_text or len(page_text) < cfg.chunk.min_size:
            continue
        docs.append(Document(
            path=str(file_path), rel_path=rel_path, file_type="pdf",
            date=date, date_source=date_source,
            heading=f"第{page_num + 1}页",
            text=page_text, sensitive=sensitive,
        ))
    doc_refit.close()

    # 如果按页切后为空（比如全文很短），整体作为一块
    if not docs and desensitized.strip():
        docs.append(Document(
            path=str(file_path), rel_path=rel_path, file_type="pdf",
            date=date, date_source=date_source,
            text=desensitized, sensitive=sensitive,
        ))

    return docs

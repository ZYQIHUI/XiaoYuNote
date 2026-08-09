"""XiaoYu 切块器 — 结构化切块 + 字符窗口回退"""

from __future__ import annotations

import logging
from typing import Optional

from ..config import Config
from ..models import Chunk, Document

logger = logging.getLogger("kb.chunker")


def chunk_documents(docs: list[Document], cfg: Config) -> list[Chunk]:
    """对 Document 列表执行切块。

    规则（r1 第 7 节）：
    - 结构化块（Excel 行分组合块、md 二级标题段、docx 标题段落）不再切；
    - 超长块走滑动窗口回退，重叠 size × overlap_ratio；
    - min_size 仅对字符窗口回退切块生效，结构化块豁免。
    """
    result: list[Chunk] = []
    seq = 0

    for doc in docs:
        if doc.sensitive:
            logger.debug(f"跳过敏感文档: {doc.rel_path}")
            continue

        chunks = _chunk_single(doc, cfg)
        for c in chunks:
            c.seq = seq
            seq += 1
            result.append(c)

    return result


def _chunk_single(doc: Document, cfg: Config) -> list[Chunk]:
    """单文档切块，根据 file_type 选择策略。"""
    text = doc.text.strip()
    if not text:
        return []

    # 结构化块：长度在 size 上限内 → 直接作为一块
    if len(text) <= cfg.chunk.size:
        if len(text) < cfg.chunk.min_size and doc.file_type == "text":
            # 纯文本短片段丢弃（结构化块豁免）
            return []
        return [_make_chunk(doc, text)]

    # 超长块：按文件类型选择断句策略后走滑动窗口
    sentences = _split_to_units(doc.file_type, text)
    return _sliding_window(sentences, doc, cfg)


def _split_to_units(file_type: str, text: str) -> list[str]:
    """按文件类型将文本拆分为可切分的基本单元。

    - md: 按段落（空行分隔）
    - text: 按段落
    - 其他: 按句号/换行
    """
    if file_type in ("markdown", "text"):
        # 按双换行分段
        parts = text.split("\n\n")
        return [p.strip() for p in parts if p.strip()]
    else:
        # 按句号或换行断开
        import re
        parts = re.split(r"(?<=[。！？\n])", text)
        return [p.strip() for p in parts if p.strip()]


def _sliding_window(
    units: list[str],
    doc: Document,
    cfg: Config,
) -> list[Chunk]:
    """滑动窗口切块，尽量在单元边界处断开。"""
    chunks: list[Document] = []
    overlap = int(cfg.chunk.size * cfg.chunk.overlap_ratio)
    current = ""

    for unit in units:
        # 单单元超过窗口上限：先输出已有缓冲区，再字符级拆分
        if len(unit) > cfg.chunk.size:
            if current and len(current) >= cfg.chunk.min_size:
                chunks.append(_make_chunk(doc, current))
            for seg in _split_long_unit(unit, cfg):
                if seg:
                    chunks.append(_make_chunk(doc, seg))
            current = ""
            continue

        candidate = (current + "\n" + unit).strip() if current else unit

        if len(candidate) <= cfg.chunk.size:
            current = candidate
        else:
            # 当前缓冲区已满，输出为一块
            if current and len(current) >= cfg.chunk.min_size:
                chunks.append(_make_chunk(doc, current))
            # 带重叠开始新块
            carry = current[-overlap:] if overlap > 0 else ""
            current = (carry + "\n" + unit).strip() if carry else unit

    # 处理剩余内容
    if current and len(current) >= cfg.chunk.min_size:
        chunks.append(_make_chunk(doc, current))

    return chunks


def _split_long_unit(unit: str, cfg: Config) -> list[str]:
    """超长单元按字符窗口拆分（带重叠），过短的尾段并入最后一块。"""
    size = cfg.chunk.size
    overlap = int(size * cfg.chunk.overlap_ratio)
    step = max(size - overlap, 1)
    parts: list[str] = []
    i = 0
    while i < len(unit):
        seg = unit[i : i + size]
        if parts and len(seg) < cfg.chunk.min_size:
            parts[-1] = parts[-1] + seg
        else:
            parts.append(seg)
        i += step
    return parts


def _make_chunk(doc: Document, text: str) -> Chunk:
    """从原始 Document 创建一个切块后的 Chunk（保留元数据）。"""
    return Chunk(
        text=text,
        file_type=doc.file_type,
        date=doc.date,
        sheet_name=doc.sheet_name,
        row_start=doc.row_start,
        row_end=doc.row_end,
        heading=doc.heading,
        rel_path=doc.rel_path,
    )

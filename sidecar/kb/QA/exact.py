"""精确值检索通道（M2）— SQL 精确匹配 + 表头上下文 + 单元格级引用。

背景：向量 top-k 对单号（D20260721002）、金额（186.50）等精确值检索弱，
本通道从问题中提取候选 token，对 cells 精确值索引做 SQL 精确/LIKE 匹配，
返回带表头上下文与单元格引用的命中（引用格式 `文件!Sheet A3`）。
"""

from __future__ import annotations

import logging
import re
from typing import Optional

logger = logging.getLogger("kb.exact")

# 字母前缀 + 数字串（单号/工号/单证号）：D20260721002、A301、B205
_TOKEN_ALNUM = re.compile(r"(?<![0-9])[A-Za-z]{1,6}[0-9]{3,}")
# 小数金额 / 4 位以上数字（日期、数量、大额）：186.50、20260721、450.00
_TOKEN_NUMBER = re.compile(r"\d+\.\d{1,4}|\d{4,}")


def extract_query_tokens(query: str) -> tuple[list[str], list[str]]:
    """从问题中提取候选精确值 token。

    Returns:
        (精确值列表, LIKE 值列表)，均去重保序。
    """
    exact: list[str] = []
    like: list[str] = []

    alnum = list(dict.fromkeys(_TOKEN_ALNUM.findall(query)))
    exact.extend(alnum)

    # 数字 token：若已被字母+数字 token 覆盖（如 D20260721002 里的 20260721002）则跳过
    for num in _TOKEN_NUMBER.findall(query):
        if not any(num in a for a in alnum):
            exact.append(num)

    # 中文 LIKE token：对每个中文段做 2~4 字滑窗，确保"已对账"等词被覆盖
    cn_tokens: set[str] = set()
    for m in re.finditer(r"[\u4e00-\u9fff]{2,}", query):
        seg = m.group(0)
        if len(seg) <= 4:
            cn_tokens.add(seg)
        else:
            for w in range(2, 5):
                for i in range(len(seg) - w + 1):
                    cn_tokens.add(seg[i : i + w])

    like = list(dict.fromkeys(sorted(cn_tokens)))
    exact = list(dict.fromkeys(exact))
    return exact, like


def _make_ref(row: dict) -> str:
    return f"{row['rel_path']}!{row['sheet_name']} {row['col_letter']}{row['row']}"


def search_exact(
    store,
    query: str,
    path_prefix: Optional[str] = None,
    top_n: int = 10,
) -> list[dict]:
    """精确值检索：精确命中优先，LIKE 兜底，去重后返回。

    Returns:
        每项含 rel_path/sheet_name/row/col/col_letter/header/value/ref。
    """
    exact, like = extract_query_tokens(query)
    if not exact and not like:
        return []

    rows_exact = (
        store.search_cells(exact_values=exact, path_prefix=path_prefix, limit=top_n)
        if exact else []
    )
    rows_like = (
        store.search_cells(like_values=like, path_prefix=path_prefix, limit=top_n * 2)
        if like else []
    )

    seen: set[tuple] = set()
    merged: list[dict] = []
    for r in rows_exact + rows_like:
        key = (r["rel_path"], r["sheet_name"], r["row"], r["col"])
        if key in seen:
            continue
        seen.add(key)
        r["ref"] = _make_ref(r)
        merged.append(r)
        if len(merged) >= top_n:
            break

    logger.info(
        f"精确检索: {query!r} → exact={len(rows_exact)} like={len(rows_like)} merged={len(merged)}"
    )
    return merged

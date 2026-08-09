"""XiaoYu 工具函数 — 日期解析、日志、凭据脱敏"""

from __future__ import annotations

import hashlib
import logging
import re
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Optional

# ------------------------------------------------------------------
# 日志配置
# ------------------------------------------------------------------

def setup_logging(level: str = "INFO", log_dir: Optional[Path] = None) -> logging.Logger:
    """配置全局日志，返回 kb 主 logger。

    安全规范：日志只记录路径、统计数字、状态标签，绝不记录 chunk 全文。

    Args:
        level: 日志级别。
        log_dir: 日志目录（默认 ./data/logs）。
    """
    logger = logging.getLogger("kb")
    if logger.handlers:
        return logger

    logger.setLevel(getattr(logging, level.upper(), logging.INFO))

    fmt = logging.Formatter(
        "%(asctime)s [%(levelname)s] %(name)s.%(funcName)s:%(lineno)d - %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    # 控制台 handler
    ch = logging.StreamHandler()
    ch.setFormatter(fmt)
    logger.addHandler(ch)

    # 文件 handler（data/logs/kb.log）
    log_dir = log_dir or Path("data/logs")
    log_dir.mkdir(parents=True, exist_ok=True)
    fh = logging.FileHandler(log_dir / "kb.log", encoding="utf-8")
    fh.setFormatter(fmt)
    logger.addHandler(fh)

    return logger


# ------------------------------------------------------------------
# 日期解析（6.6 节）
# ------------------------------------------------------------------

_DATE_RE = re.compile(r"20\d{2}[-/.年]?\d{1,2}[-/.月]?\d{1,2}日?")


def extract_date_from_path(file_path: Path) -> tuple[Optional[int], str]:
    """从文件路径提取日期，按优先级：祖先目录名 > 文件名 > mtime。

    Returns:
        (YYYYMMDD 整数, 来源标识)
    """
    # 优先级 1：最近的含日期祖先目录名
    for parent in file_path.parents:
        m = _DATE_RE.search(parent.name)
        if m:
            d = _normalize_date(m.group())
            if d:
                return d, "dirname"

    # 优先级 2：文件名
    m = _DATE_RE.search(file_path.name)
    if m:
        d = _normalize_date(m.group())
        if d:
            return d, "filename"

    # 优先级 4：mtime 兜底
    try:
        mt = datetime.fromtimestamp(file_path.stat().st_mtime)
        return mt.year * 10000 + mt.month * 100 + mt.day, "mtime"
    except OSError:
        return None, "none"


def extract_date_from_content(first_lines: list[str]) -> tuple[Optional[int], str]:
    """从内容首行/头部提取日期（优先级 3）。

    Args:
        first_lines: 文件前几行文本。
    """
    for line in first_lines[:3]:
        m = _DATE_RE.search(line.strip())
        if m:
            d = _normalize_date(m.group())
            if d:
                return d, "content"
    return None, "none"


def _normalize_date(raw: str) -> Optional[int]:
    """将各种日期格式归一化为 YYYYMMDD 整数。"""
    raw = raw.strip()

    # 1) 8 位纯数字（YYYYMMDD，如来自 "2026-07-21" 去除分隔符）
    digits = re.sub(r"\D", "", raw)
    if len(digits) == 8 and digits.isdigit():
        y, mo, d = int(digits[:4]), int(digits[4:6]), int(digits[6:8])
        if 2000 <= y <= 2099 and 1 <= mo <= 12 and 1 <= d <= 31:
            return y * 10000 + mo * 100 + d

    # 2) 带分隔符的年/月/日（2026-7-15、2026年7月15日、2026/07/15、2026.7.15）
    m = re.match(r"(\d{4})\s*[年/\-.]\s*(\d{1,2})\s*[月/\-.]\s*(\d{1,2})", raw)
    if m:
        y, mo, d = (int(g) for g in m.groups())
        if 2000 <= y <= 2099 and 1 <= mo <= 12 and 1 <= d <= 31:
            return y * 10000 + mo * 100 + d

    return None


# ------------------------------------------------------------------
# 哈希
# ------------------------------------------------------------------

def file_sha256(path: Path) -> str:
    """计算文件 SHA256 哈希值（用于增量判重）。"""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


# ------------------------------------------------------------------
# 凭据脱敏（6.8 节 — r1 收紧版）
# ------------------------------------------------------------------

_SENSITIVE_MAIN_RE = re.compile(
    r"(密码|口令|password|secret|支付密码|登录密码)[:：= ]\S{8,}",
    re.IGNORECASE,
)

_SENSITIVE_COOCCUR_FIELDS = r"(账号|appid|api[_-]?key|sqycKey|token)"
_SENSITIVE_COOCCUR_TRIGGERS = r"(密码|口令|password|secret)"
_SENSITIVE_COOCCUR_RE = re.compile(
    rf"{_SENSITIVE_COOCCUR_FIELDS}[:：= ]\S+"
    rf".*{_SENSITIVE_COOCCUR_TRIGGERS}"
    rf"|{_SENSITIVE_COOCCUR_TRIGGERS}"
    rf".*{_SENSITIVE_COOCCUR_FIELDS}[:：= ]\S+",
    re.IGNORECASE | re.DOTALL,
)


def desensitize(text: str) -> tuple[str, int]:
    """对单条文本执行凭据脱敏。

    Returns:
        (脱敏后文本, 脱敏命中次数)
    """
    count = 0

    # 共现模式：账号类字段与密码类高危词共现
    matches = list(_SENSITIVE_COOCCUR_RE.finditer(text))
    for m in reversed(matches):  # 从后往前替换，不破坏位置
        text = text[:m.start()] + "[已脱敏]" + text[m.end():]
        count += 1

    # 主模式：密码类字段后跟长值
    matches = list(_SENSITIVE_MAIN_RE.finditer(text))
    for m in reversed(matches):
        text = text[:m.start()] + "[已脱敏]" + text[m.end():]
        count += 1

    return text, count


def is_sensitive_file(desensitize_count: int, path_hint: str = "") -> bool:
    """判断文件是否应标记为敏感文件。

    规则：
    - 单文件脱敏次数 > 阈值（默认 3 次）；
    - 或路径命中 `实操环境` / `source` 特征。
    """
    if desensitize_count > 3:
        return True
    hint_lower = path_hint.lower()
    if any(kw in hint_lower for kw in ("实操环境", "source", ".env", "config")):
        return True
    return False


# ------------------------------------------------------------------
# 时间词解析（9.0 节 — 查询理解）
# ------------------------------------------------------------------

_TIME_PATTERNS = {
    "上周": lambda d: _week_range(d, -1),
    "本周": lambda d: _week_range(d, 0),
    "下周": lambda d: _week_range(d, 1),
    "上月": lambda d: _month_range(d, -1),
    "本月": lambda d: _month_range(d, 0),
    "下月": lambda d: _month_range(d, 1),
}


def parse_time_query(query: str, today: Optional[date] = None) -> Optional[tuple[int, int]]:
    """从用户问题中解析时间词为 date_range (start_YYYYMMDD, end_YYYYMMDD)。

    Returns:
        (start, end) 或 None（无时间词或无法解析）。
    """
    today = today or date.today()
    for keyword, fn in _TIME_PATTERNS.items():
        if keyword in query:
            return fn(today)
    return None


def _week_range(d: date, offset: int) -> tuple[int, int]:
    """给定日期所在周的周一到周日，支持偏移。"""
    monday = d - timedelta(days=d.weekday()) + timedelta(weeks=offset)
    sunday = monday + timedelta(days=6)
    return _date_to_int(monday), _date_to_int(sunday)


def _month_range(d: date, offset: int) -> tuple[int, int]:
    """给定日期所在月的 1 号到最后一天，支持偏移。"""
    year = d.year + (d.month + offset - 1) // 12
    month = (d.month - 1 + offset) % 12 + 1
    first = date(year, month, 1)
    import calendar
    last_day = calendar.monthrange(year, month)[1]
    last = date(year, month, last_day)
    return _date_to_int(first), _date_to_int(last)


def _date_to_int(d: date) -> int:
    return d.year * 10000 + d.month * 100 + d.day

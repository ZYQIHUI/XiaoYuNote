"""XiaoYu 数据模型 — Document / Chunk / FileRecord"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


@dataclass
class Document:
    """解析器对单个源文件提取出的结构化产物（含文本与元数据）。"""

    path: str                          # 源文件绝对路径
    rel_path: str                      # 相对项目根路径（用于展示与去重）
    file_type: str                     # excel | markdown | text | docx | pdf
    date: int = 0                      # 整数日期 YYYYMMDD
    date_source: str = "none"          # dirname | filename | content | mtime | none
    sheet_name: Optional[str] = None   # Excel 专属
    row_start: Optional[int] = None    # Excel 行分组合块起始行
    row_end: Optional[int] = None      # Excel 行分组合块结束行
    heading: Optional[str] = None      # md 专属：所属二级标题
    text: str = ""                     # 切块后的文本
    sensitive: bool = False            # 是否命中凭据脱敏/跳过


@dataclass
class Chunk:
    """检索单元，Document 经切块后得到的最小可检索片段。"""

    id: int = 0
    file_id: int = 0
    seq: int = 0                       # 文件内块序号
    text: str = ""
    embedding: Optional[list[float]] = None   # float32 向量（运行时）
    date: int = 0
    file_type: str = ""
    sheet_name: Optional[str] = None
    row_start: Optional[int] = None
    row_end: Optional[int] = None
    heading: Optional[str] = None
    status: str = "ok"                 # ok | pending | failed

    # 非持久化字段（JOIN 查询时填充）
    rel_path: str = ""


@dataclass
class FileRecord:
    """files 表记录。"""

    id: int = 0
    rel_path: str = ""
    file_hash: str = ""
    size_bytes: int = 0
    mtime_ns: int = 0
    date: int = 0
    date_source: str = "none"
    parsed_at: str = ""
    status: str = "ok"                # ok | skipped | no_text | sensitive


@dataclass
class CellRecord:
    """cells 表记录 — Excel 精确值索引（M2：表格感知问答底子）。

    单号/金额等精确值走 SQL 精确匹配，弥补向量 top-k 对精确值检索弱的问题。
    row/col 为 Excel 1-based 坐标（含表头行），col_letter 为 A/B/C… 列字母。
    """

    file_id: int = 0
    rel_path: str = ""
    sheet_name: str = ""
    row: int = 0                       # Excel 1-based 行号
    col: int = 0                       # Excel 1-based 列号
    col_letter: str = ""               # A/B/C…
    header: str = ""                   # 该列的表头（无表头则为空）
    value: str = ""                    # 单元格文本（脱敏后）


@dataclass
class ScanResult:
    """扫描结果统计。"""

    total_files: int = 0
    new_files: list[Path] = field(default_factory=list)
    changed_files: list[Path] = field(default_factory=list)
    skipped_files: list[Path] = field(default_factory=list)     # 未变化
    excluded_files: list[str] = field(default_factory=list)     # 黑名单/扩展名排除
    sensitive_files: list[Path] = field(default_factory=list)
    error_files: list[tuple[Path, str]] = field(default_factory=list)  # (path, error_msg)
    deleted_rel_paths: list[str] = field(default_factory=list)  # 磁盘上已删除

"""XiaoYu 扫描器 — 目录递归、黑白名单、日期提取、文件统计"""

from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import Optional

from ..config import Config
from ..models import ScanResult, FileRecord
from ..utils import extract_date_from_path, file_sha256

logger = logging.getLogger("kb.scanner")


def scan(cfg: Config, dry_run: bool = False, source: Optional[str] = None) -> ScanResult:
    """递归扫描工作区，返回增量判重结果。

    Args:
        cfg: 全局配置。
        dry_run: 仅统计，不实际入库。
        source: 只扫描指定源目录（如 "个人"），默认扫描全部数据源。

    Returns:
        ScanResult 包含各类文件清单与统计。
    """
    result = ScanResult()
    root = cfg.root_dir

    # 1) 收集所有候选文件
    sources = [source] if source else cfg.data.sources
    all_files: list[Path] = []
    for source_name in sources:
        # 支持绝对路径（外部知识库文件夹）与相对路径（数据目录内业务区）
        source_path = Path(source_name) if Path(source_name).is_absolute() else root / source_name
        if not source_path.exists():
            logger.warning(f"数据源目录不存在: {source_path}")
            continue
        all_files.extend(_walk(source_path, cfg))

    result.total_files = len(all_files)

    # 2) 增量判重（需要 store，dry_run 时跳过）
    from .store import Store
    store = Store(cfg)
    existing = store.get_all_files()  # {rel_path: FileRecord}

    existing_rel_paths = set(existing.keys())
    disk_rel_paths: set[str] = set()

    for fpath in all_files:
        try:
            rel = fpath.relative_to(root).as_posix()
        except ValueError:
            # 外部知识库文件夹（在数据目录之外）：用源目录名作为顶层前缀
            rel = _external_rel(fpath, cfg)
        disk_rel_paths.add(rel)

        # 黑名单检查
        if _is_excluded(fpath, rel, cfg):
            result.excluded_files.append(rel)
            continue

        # 增量判重
        record = existing.get(rel)
        stat = fpath.stat()

        if record is not None:
            # size + mtime 快速跳过
            if record.size_bytes == stat.st_size and record.mtime_ns == stat.st_mtime_ns:
                result.skipped_files.append(fpath)
                continue

            # mtime 变了 → 算 sha256 确认
            current_hash = file_sha256(fpath)
            if current_hash == record.file_hash:
                # 内容没变，只更新 mtime
                store.update_mtime(record.id, stat.st_mtime_ns)
                result.skipped_files.append(fpath)
                continue

            # 内容变了 → 标记为变更
            result.changed_files.append(fpath)
        else:
            # 新文件
            result.new_files.append(fpath)

    # 3) 检测已删除文件（r1 P2.12）
    deleted = existing_rel_paths - disk_rel_paths
    result.deleted_rel_paths = sorted(deleted)

    # 4) 日志汇总
    logger.info(
        f"扫描完成: 总计 {len(all_files)} 文件 | "
        f"新增 {len(result.new_files)} | 变更 {len(result.changed_files)} | "
        f"跳过 {len(result.skipped_files)} | 排除 {len(result.excluded_files)} | "
        f"已删除 {len(result.deleted_rel_paths)}"
    )

    return result


def _external_rel(fpath: Path, cfg: Config) -> str:
    """外部知识库文件的相对路径：{源目录名}/{相对源目录}。"""
    abs_fpath = fpath.resolve()
    for source_name in cfg.data.sources:
        sp = Path(source_name)
        if not sp.is_absolute():
            continue
        abs_source = sp.resolve()
        try:
            return abs_fpath.relative_to(abs_source).as_posix()
        except ValueError:
            continue
    # 兜底：用文件名（极少触发）
    return fpath.name


def _walk(base: Path, cfg: Config) -> list[Path]:
    """递归收集白名单扩展名文件，排除黑名单路径。"""
    """递归收集白名单扩展名文件，排除黑名单路径。"""
    results: list[Path] = []
    excluded_dirs = [d.lower() for d in cfg.data.exclude_dirs]

    for dirpath, dirnames, filenames in os.walk(base):
        # 过滤黑名单目录（原地修改 dirnames 阻止 os.walk 进入）
        dirnames[:] = [
            d for d in dirnames
            if d.lower() not in excluded_dirs and not d.startswith(".")
        ]

        for fname in filenames:
            ext = fname.split(".")[-1].lower() if "." in fname else ""
            if ext in ("md", "txt", "xlsx", "xls", "docx", "pdf"):
                fpath = Path(dirpath) / fname
                # 文件大小上限
                if fpath.stat().st_size > cfg.data.max_file_mb * 1024 * 1024:
                    logger.warning(f"文件过大，跳过: {fpath} ({fpath.stat().st_size / 1024 / 1024:.1f}MB)")
                    continue
                results.append(fpath)

    return results


def _is_excluded(fpath: Path, rel: str, cfg: Config) -> bool:
    """检查文件是否应被排除。"""
    # 路径黑名单
    for excl_dir in cfg.data.exclude_dirs:
        if f"/{excl_dir}/" in rel or rel.startswith(f"{excl_dir}/"):
            return True
    # 扩展名黑名单
    ext = fpath.suffix.lstrip(".").lower()
    if ext in cfg.data.exclude_exts:
        return True
    return False

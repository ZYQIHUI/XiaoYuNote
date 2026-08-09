"""watchdog 自动索引：监听数据目录（notes + 业务双区）→ 防抖 → 增量索引。

用法：
    python -m sidecar.watch            # 前台运行
    python -m sidecar.watch --rebuild  # 启动时先全量重建再监听

索引在独立线程执行，失败不崩溃（日志 + 跳过）。
"""

from __future__ import annotations

import argparse
import logging
import threading
import time
from pathlib import Path

from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer

logger = logging.getLogger("sidecar.watch")

# 忽略目录/文件：缓存、git、数据库、配置
IGNORE_DIRS = {".git", "__pycache__", ".venv", "node_modules", "data", "build", ".dart_tool"}
IGNORE_EXTS = {".pyc", ".sqlite3", ".db", ".json", ".lock"}
DEBOUNCE_SECONDS = 2.0


def _relevant(path_str: str) -> bool:
    p = Path(path_str)
    if p.name.startswith("."):
        return False
    if p.suffix.lower() in IGNORE_EXTS:
        return False
    return True


class _IndexHandler(FileSystemEventHandler):
    def __init__(self, index_fn, debounce: float = DEBOUNCE_SECONDS):
        self._index_fn = index_fn
        self._debounce = debounce
        self._timer: threading.Timer | None = None
        self._lock = threading.Lock()

    def _schedule(self) -> None:
        with self._lock:
            if self._timer is not None:
                self._timer.cancel()
            self._timer = threading.Timer(self._debounce, self._run)
            self._timer.daemon = True
            self._timer.start()

    def _run(self) -> None:
        try:
            logger.info("文件变更，触发增量索引…")
            stats = self._index_fn()
            logger.info(f"索引完成: {stats}")
        except Exception as e:
            logger.error(f"索引失败（已跳过，待下次变更重试）: {e}")
        finally:
            with self._lock:
                self._timer = None

    def on_created(self, event) -> None:
        if not event.is_directory and _relevant(event.src_path):
            self._schedule()

    def on_modified(self, event) -> None:
        if not event.is_directory and _relevant(event.src_path):
            self._schedule()

    def on_deleted(self, event) -> None:
        if not event.is_directory and _relevant(event.src_path):
            self._schedule()

    def on_moved(self, event) -> None:
        if not event.is_directory and (_relevant(event.src_path) or _relevant(event.dest_path)):
            self._schedule()


def watch(data_dir: Path, rebuild: bool = False) -> Observer:
    """启动监听，返回 Observer。"""
    from .server import run_index

    data_dir = Path(data_dir)
    if rebuild:
        logger.info("启动前全量重建索引…")
        run_index(data_dir, rebuild=True)

    handler = _IndexHandler(lambda: run_index(data_dir, rebuild=False))
    observer = Observer()
    observer.schedule(handler, str(data_dir), recursive=True)
    observer.daemon = True
    observer.start()
    logger.info(f"watchdog 已监听: {data_dir}")
    return observer


def main() -> None:
    from .server import DATA_DIR

    parser = argparse.ArgumentParser(description="XiaoYu 自动索引 watchdog")
    parser.add_argument("--rebuild", action="store_true", help="启动时先全量重建")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
    observer = watch(DATA_DIR, rebuild=args.rebuild)
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()


if __name__ == "__main__":
    main()

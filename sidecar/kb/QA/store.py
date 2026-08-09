"""XiaoYu 存储层 — SQLite 建表、写入、哈希判重、查询、文件删除同步"""

from __future__ import annotations

import logging
import sqlite3
from datetime import datetime
from pathlib import Path
from typing import Optional

from ..config import Config
from ..models import CellRecord, Chunk, FileRecord

logger = logging.getLogger("kb.store")


class Store:
    """SQLite 本地持久化层（r1 第 5 节 DDL）。"""

    def __init__(self, cfg: Config) -> None:
        self._cfg = cfg
        self._db_path = cfg.root_dir / cfg.store.path
        self._db_path.parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(str(self._db_path))
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._init_tables()

    # ------------------------------------------------------------------
    # 建表（含 meta 表，r1 P0.4）
    # ------------------------------------------------------------------

    def _init_tables(self) -> None:
        self._conn.executescript("""
            CREATE TABLE IF NOT EXISTS files (
                id            INTEGER PRIMARY KEY,
                rel_path      TEXT UNIQUE NOT NULL,
                file_hash     TEXT NOT NULL,
                size_bytes    INTEGER NOT NULL,
                mtime_ns      INTEGER NOT NULL,
                date          INTEGER,
                date_source   TEXT,
                parsed_at     TEXT NOT NULL,
                status        TEXT NOT NULL DEFAULT 'ok'
            );

            CREATE TABLE IF NOT EXISTS chunks (
                id         INTEGER PRIMARY KEY,
                file_id    INTEGER NOT NULL REFERENCES files(id),
                seq        INTEGER NOT NULL,
                text       TEXT NOT NULL,
                embedding  BLOB,
                date       INTEGER,
                file_type  TEXT,
                sheet_name TEXT,
                row_start  INTEGER,
                row_end    INTEGER,
                heading    TEXT,
                status     TEXT NOT NULL DEFAULT 'ok',
                UNIQUE (file_id, seq)
            );

            CREATE TABLE IF NOT EXISTS meta (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS cells (
                id         INTEGER PRIMARY KEY,
                file_id    INTEGER NOT NULL REFERENCES files(id),
                rel_path   TEXT NOT NULL,
                sheet_name TEXT NOT NULL,
                row        INTEGER NOT NULL,
                col        INTEGER NOT NULL,
                col_letter TEXT NOT NULL,
                header     TEXT,
                value      TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_chunks_date ON chunks(date);
            CREATE INDEX IF NOT EXISTS idx_chunks_file ON chunks(file_id);
            CREATE INDEX IF NOT EXISTS idx_files_hash ON files(file_hash);
            CREATE INDEX IF NOT EXISTS idx_cells_file ON cells(file_id);
            CREATE INDEX IF NOT EXISTS idx_cells_value ON cells(value);
            CREATE INDEX IF NOT EXISTS idx_cells_rel ON cells(rel_path);
        """)
        self._conn.commit()

    # ------------------------------------------------------------------
    # 文件操作
    # ------------------------------------------------------------------

    def get_all_files(self) -> dict[str, FileRecord]:
        """获取所有文件记录 {rel_path: FileRecord}。"""
        rows = self._conn.execute("SELECT * FROM files").fetchall()
        return {
            r["rel_path"]: FileRecord(
                id=r["id"], rel_path=r["rel_path"], file_hash=r["file_hash"],
                size_bytes=r["size_bytes"], mtime_ns=r["mtime_ns"],
                date=r["date"] or 0, date_source=r["date_source"],
                parsed_at=r["parsed_at"], status=r["status"],
            )
            for r in rows
        }

    def upsert_file(self, record: FileRecord) -> int:
        """插入或更新文件记录，返回 file_id。"""
        cur = self._conn.execute("""
            INSERT INTO files (rel_path, file_hash, size_bytes, mtime_ns, date, date_source, parsed_at, status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(rel_path) DO UPDATE SET
                file_hash=excluded.file_hash,
                size_bytes=excluded.size_bytes,
                mtime_ns=excluded.mtime_ns,
                date=excluded.date,
                date_source=excluded.date_source,
                parsed_at=excluded.parsed_at,
                status=excluded.status
        """, (
            record.rel_path, record.file_hash, record.size_bytes, record.mtime_ns,
            record.date or None, record.date_source, record.parsed_at, record.status,
        ))
        self._conn.commit()
        return cur.lastrowid  # type: ignore

    def update_mtime(self, file_id: int, mtime_ns: int) -> None:
        """仅更新修改时间（内容未变时快速跳过）。"""
        self._conn.execute(
            "UPDATE files SET mtime_ns=? WHERE id=?", (mtime_ns, file_id)
        )
        self._conn.commit()

    def delete_file(self, file_id: int) -> None:
        """级联删除文件及其所有 chunks 与 cells（事务内原子操作）。"""
        with self._conn:
            self._conn.execute("DELETE FROM chunks WHERE file_id=?", (file_id,))
            self._conn.execute("DELETE FROM cells WHERE file_id=?", (file_id,))
            self._conn.execute("DELETE FROM files WHERE id=?", (file_id,))

    def clear_chunks(self, rel_path: str) -> None:
        """删除指定文件的全部 chunks（文件变更重入库前清理，防止旧 seq 残留）。"""
        row = self._conn.execute(
            "SELECT id FROM files WHERE rel_path=?", (rel_path,)
        ).fetchone()
        if row:
            self._conn.execute(
                "DELETE FROM chunks WHERE file_id=?", (row["id"],)
            )
            self._conn.commit()

    def prune_deleted(self, existing_rel_paths: set[str]) -> list[str]:
        """删除磁盘上已不存在的文件的记录（r1 P2.12）。

        Returns:
            被删除的 rel_path 列表。
        """
        all_rel = {
            r[0] for r in
            self._conn.execute("SELECT rel_path FROM files").fetchall()
        }
        deleted = sorted(all_rel - existing_rel_paths)
        for rel in deleted:
            row = self._conn.execute(
                "SELECT id FROM files WHERE rel_path=?", (rel,)
            ).fetchone()
            if row:
                self.delete_file(row["id"])
                logger.info(f"清理已删除文件: {rel}")
        return deleted

    # ------------------------------------------------------------------
    # Chunk 操作
    # ------------------------------------------------------------------

    def upsert_chunk_placeholders(self, chunks: list[Chunk]) -> list[int]:
        """写入 chunk 占位行（status='pending', embedding=NULL），返回 file_ids。

        幂等：先 DELETE 再重插。
        """
        file_ids: list[int] = []
        for ch in chunks:
            if ch.file_id == 0:
                # 需要先确保 file 记录存在
                file_id = self._ensure_file(ch.rel_path)
                ch.file_id = file_id
            else:
                file_id = ch.file_id

            # 原子替换
            self._conn.execute(
                "DELETE FROM chunks WHERE file_id=? AND seq=?",
                (ch.file_id, ch.seq),
            )
            self._conn.execute("""
                INSERT INTO chunks
                    (file_id, seq, text, embedding, date, file_type, sheet_name,
                     row_start, row_end, heading, status)
                VALUES (?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, 'pending')
            """, (
                ch.file_id, ch.seq, ch.text, ch.date or None, ch.file_type,
                ch.sheet_name, ch.row_start, ch.row_end, ch.heading,
            ))
            file_ids.append(file_id)

        self._conn.commit()
        return file_ids

    def _ensure_file(self, rel_path: str) -> int:
        """确保 files 表中有对应记录（无则插入占位）。"""
        row = self._conn.execute(
            "SELECT id FROM files WHERE rel_path=?", (rel_path,)
        ).fetchone()
        if row:
            return row["id"]
        cur = self._conn.execute("""
            INSERT INTO files (rel_path, file_hash, size_bytes, mtime_ns, parsed_at, status)
            VALUES ('', 0, 0, 0, ?, 'pending')
        """, (datetime.now().isoformat(),))
        self._conn.commit()
        return cur.lastrowid  # type: ignore

    def update_chunk_embedding(self, chunk: Chunk, embedding: list[float]) -> None:
        """向量化完成后更新 embedding 和 status。"""
        import struct
        blob = struct.pack(f"{len(embedding)}f", *embedding)
        self._conn.execute("""
            UPDATE chunks SET embedding=?, status='ok' WHERE file_id=? AND seq=?
        """, (blob, chunk.file_id, chunk.seq))
        self._conn.commit()

    def update_chunk_status(self, chunk: Chunk, status: str) -> None:
        """更新 chunk 状态（failed 等）。"""
        self._conn.execute(
            "UPDATE chunks SET status=? WHERE file_id=? AND seq=?",
            (status, chunk.file_id, chunk.seq),
        )
        self._conn.commit()

    # ------------------------------------------------------------------
    # 检索查询
    # ------------------------------------------------------------------

    def get_all_chunks_for_retrieval(
        self,
        date_range: Optional[tuple[int, int]] = None,
        file_types: Optional[list[str]] = None,
        path_prefix: Optional[str] = None,
        include_null_date: bool = True,
    ) -> list[dict]:
        """获取用于检索的 chunks（r1 P0.2: JOIN files 取 rel_path）。

        Args:
            date_range: (start_YYYYMMDD, end_YYYYMMDD)
            file_types: 过滤文件类型列表
            path_prefix: 路径前缀过滤（如 '小组/%'）
            include_null_date: 是否包含无法提取日期的块
        """
        conditions: list[str] = ["c.status='ok'"]
        params: list = []

        if date_range is not None:
            if include_null_date:
                conditions.append(
                    "(c.date BETWEEN ? AND ? OR c.date IS NULL)"
                )
            else:
                conditions.append("c.date BETWEEN ? AND ?")
            params.extend(date_range)

        if file_types:
            placeholders = ",".join("?" * len(file_types))
            conditions.append(f"c.file_type IN ({placeholders})")
            params.extend(file_types)

        if path_prefix:
            conditions.append("f.rel_path LIKE ?")
            params.append(f"{path_prefix}%")

        where = " AND ".join(conditions)
        sql = f"""
            SELECT c.id, c.file_id, c.seq, c.text, c.embedding,
                   c.date, c.file_type, c.sheet_name,
                   c.row_start, c.row_end, c.heading,
                   f.rel_path
            FROM chunks c
            JOIN files f ON c.file_id = f.id
            WHERE {where}
        """
        rows = self._conn.execute(sql, params).fetchall()
        return [dict(r) for r in rows]

    # ------------------------------------------------------------------
    # Meta 操作（r1 P0.4）
    # ------------------------------------------------------------------

    def get_meta(self, key: str) -> Optional[str]:
        row = self._conn.execute(
            "SELECT value FROM meta WHERE key=?", (key,)
        ).fetchone()
        return row["value"] if row else None

    def set_meta(self, key: str, value: str) -> None:
        self._conn.execute(
            "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
            (key, value),
        )
        self._conn.commit()

    def check_embedding_model(self, model_name: str) -> bool:
        """检查当前模型是否与库中记录一致（r1 换模型防护）。

        Returns:
            True 表示一致或首次建库；False 表示不一致需 reset。
        """
        stored = self.get_meta("embedding_model")
        if stored is None:
            # 首次建库，记录模型
            self.set_meta("embedding_model", model_name)
            self.set_meta("schema_version", "1")
            self.set_meta("created_at", datetime.now().isoformat())
            return True
        return stored == model_name

    # ------------------------------------------------------------------
    # 统计
    # ------------------------------------------------------------------

    # ------------------------------------------------------------------
    # 精确值单元格索引（M2：表格感知问答）
    # ------------------------------------------------------------------

    def replace_cells(self, rel_path: str, cells: list[CellRecord]) -> None:
        """重建某文件的精确值索引：删除旧 cells + 批量插入。"""
        self._conn.execute("DELETE FROM cells WHERE rel_path=?", (rel_path,))
        if not cells:
            self._conn.commit()
            return
        file_id = self._ensure_file(rel_path)
        self._conn.executemany(
            """INSERT INTO cells (file_id, rel_path, sheet_name, row, col, col_letter, header, value)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            [
                (
                    file_id, c.rel_path, c.sheet_name, c.row, c.col,
                    c.col_letter, c.header, c.value,
                )
                for c in cells
            ],
        )
        self._conn.commit()

    def clear_cells(self, rel_path: str) -> None:
        """删除某文件全部精确值索引（文件被删时）。"""
        self._conn.execute("DELETE FROM cells WHERE rel_path=?", (rel_path,))
        self._conn.commit()

    def search_cells(
        self,
        exact_values: Optional[list[str]] = None,
        like_values: Optional[list[str]] = None,
        path_prefix: Optional[str] = None,
        limit: int = 50,
    ) -> list[dict]:
        """精确值检索：value 全等匹配优先，LIKE 兜底。

        Returns:
            每项含 rel_path/sheet_name/row/col/col_letter/header/value。
        """
        clauses: list[str] = []
        params: list = []
        if exact_values:
            placeholders = ",".join("?" for _ in exact_values)
            clauses.append(f"value IN ({placeholders})")
            params.extend(exact_values)
        if like_values:
            for lv in like_values:
                clauses.append("value LIKE ?")
                params.append(f"%{lv}%")
        if path_prefix:
            clauses.append("rel_path LIKE ?")
            params.append(f"{path_prefix}%")
        if not clauses:
            return []
        sql = "SELECT * FROM cells WHERE " + " OR ".join(clauses)
        sql += " ORDER BY rel_path, sheet_name, row, col LIMIT ?"
        params.append(limit)
        rows = self._conn.execute(sql, params).fetchall()
        return [
            {
                "rel_path": r["rel_path"],
                "sheet_name": r["sheet_name"],
                "row": r["row"],
                "col": r["col"],
                "col_letter": r["col_letter"],
                "header": r["header"] or "",
                "value": r["value"],
            }
            for r in rows
        ]

    def cell_stats(self) -> int:
        """cells 表总行数。"""
        return self._conn.execute("SELECT COUNT(*) FROM cells").fetchone()[0]

    def stats(self) -> dict:
        """库统计信息。"""
        file_count = self._conn.execute("SELECT COUNT(*) FROM files").fetchone()[0]
        chunk_count = self._conn.execute(
            "SELECT COUNT(*) FROM chunks WHERE status='ok'"
        ).fetchone()[0]

        by_type = dict(
            self._conn.execute("""
                SELECT file_type, COUNT(*) FROM chunks WHERE status='ok'
                GROUP BY file_type
            """).fetchall()
        )

        by_status = dict(
            self._conn.execute("""
                SELECT status, COUNT(*) FROM chunks GROUP BY status
            """).fetchall()
        )

        return {
            "files": file_count,
            "chunks": chunk_count,
            "by_type": by_type,
            "by_status": by_status,
        }

    # ------------------------------------------------------------------
    # 清理
    # ------------------------------------------------------------------

    def reset(self) -> None:
        """清空向量库（重建用）。"""
        with self._conn:
            self._conn.execute("DELETE FROM chunks")
            self._conn.execute("DELETE FROM files")
            self._conn.execute("DELETE FROM meta")
        logger.warning("向量库已清空")

    def close(self) -> None:
        self._conn.close()

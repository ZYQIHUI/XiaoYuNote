"""存储层单元测试 — sha256 判重、mtime 快速跳过、原子替换"""

import pytest
import tempfile
from pathlib import Path
from kb.config import Config
from kb.QA.store import Store
from kb.models import FileRecord


class TestStoreDedup:
    """增量判重算法验证。"""

    @pytest.fixture
    def temp_store(self, tmp_path):
        """创建临时 SQLite 存储实例。"""
        cfg = Config()
        cfg.store.path = str(tmp_path / "test_kb.sqlite3")
        return Store(cfg)

    def test_upsert_new_file(self, temp_store):
        """新文件插入成功。"""
        record = FileRecord(
            rel_path="个人/2026-7-15/test.md",
            file_hash="abc123",
            size_bytes=1024,
            mtime_ns=1000000,
            date=20260715,
            date_source="dirname",
            parsed_at="2026-08-05T10:00:00",
        )
        fid = temp_store.upsert_file(record)
        assert fid > 0

        all_files = temp_store.get_all_files()
        assert "个人/2026-7-15/test.md" in all_files

    def test_upsert_duplicate_path_updates(self, temp_store):
        """同路径重复插入更新而非新增。"""
        r1 = FileRecord(
            rel_path="test.txt", file_hash="hash1",
            size_bytes=100, mtime_ns=1, date=20260701,
            date_source="filename", parsed_at="t1",
        )
        fid1 = temp_store.upsert_file(r1)

        r2 = FileRecord(
            rel_path="test.txt", file_hash="hash2",
            size_bytes=200, mtime_ns=2, date=20260702,
            date_source="filename", parsed_at="t2",
        )
        fid2 = temp_store.upsert_file(r2)

        # 同一 rel_path 应该更新，ID 可能相同或不同但总数应为 1
        all_files = temp_store.get_all_files()
        assert len(all_files) == 1
        assert all_files["test.txt"].file_hash == "hash2"

    def test_delete_cascades_chunks(self, temp_store):
        """删除文件时级联删除其 chunks。"""
        # 先插入文件
        record = FileRecord(
            rel_path="to_delete.md", file_hash="h",
            size_bytes=50, mtime_ns=1, date=20260701,
            date_source="none", parsed_at="t",
        )
        fid = temp_store.upsert_file(record)

        # 插入几个 chunks
        for i in range(3):
            temp_store._conn.execute("""
                INSERT INTO chunks (file_id, seq, text, status)
                VALUES (?, ?, ?, 'ok')
            """, (fid, i, f"chunk {i}"))
        temp_store._conn.commit()

        # 删除文件
        temp_store.delete_file(fid)

        # 验证 chunks 也被删了
        remaining = temp_store._conn.execute(
            "SELECT COUNT(*) FROM chunks WHERE file_id=?", (fid,)
        ).fetchone()[0]
        assert remaining == 0

    def test_meta_operations(self, temp_store):
        """meta 表读写（r1 P0.4）。"""
        temp_store.set_meta("test_key", "test_value")
        assert temp_store.get_meta("test_key") == "test_value"

        assert temp_store.get_meta("nonexistent") is None

    def test_model_check_first_time(self, temp_store):
        """首次建库时记录模型名。"""
        assert temp_store.check_embedding_model("bge-m3") is True
        assert temp_store.get_meta("embedding_model") == "bge-m3"

    def test_model_check_same_ok(self, temp_store):
        """相同模型通过检查。"""
        temp_store.set_meta("embedding_model", "bge-m3")
        assert temp_store.check_embedding_model("bge-m3") is True

    def test_model_check_different_fails(self, temp_store):
        """不同模型检查失败（r1 换模型防护）。"""
        temp_store.set_meta("embedding_model", "bge-m3")
        assert temp_store.check_embedding_model("text-embedding-3-small") is False

    def test_reset_clears_all(self, temp_store):
        """reset 清空所有表。"""
        temp_store.upsert_file(FileRecord(
            rel_path="x", file_hash="h", size_bytes=1,
            mtime_ns=1, date=0, date_source="none", parsed_at="t",
        ))
        temp_store.reset()

        assert temp_store.stats()["files"] == 0
        assert temp_store.stats()["chunks"] == 0
        assert temp_store.get_meta("embedding_model") is None

"""watchdog 自动索引测试 — 文件创建 → 防抖 → 增量索引入库。

embedding mock（不依赖外部 API）；observer 用真实 watchdog。
"""

import time

import numpy as np
import pytest

MD_DAILY = """# 2026-7-15 日报

## 今日完成
- 拼房对账：单据 D20260721002 金额 186.50 状态 已对账
"""


class FakeEmbed:
    DIM = 1024

    def __init__(self, cfg=None):
        self.rng = np.random.default_rng(7)

    def embed(self, texts):
        return [self._vec() for _ in texts]

    def embed_one(self, text):
        return self._vec()

    def _vec(self):
        v = self.rng.standard_normal(self.DIM).astype(np.float32)
        return (v / np.linalg.norm(v)).tolist()


def _file_count(tmp_path) -> int:
    from kb.config import Config
    from kb.QA.store import Store

    cfg = Config(root_dir=tmp_path)
    cfg.store.path = "kb.sqlite3"
    cfg.data.sources = ["个人", "notes"]
    store = Store(cfg)
    n = len(store.get_all_files())
    store.close()
    return n


@pytest.fixture
def mock_embed(monkeypatch):
    monkeypatch.setattr("kb.QA.embedder.LLMClient", FakeEmbed)


def test_watch_indexes_new_file(tmp_path, monkeypatch, mock_embed):
    """创建新文件 → watchdog 防抖后自动增量入库。"""
    monkeypatch.setenv("XIAOYU_DATA_DIR", str(tmp_path))
    from sidecar.watch import watch

    observer = watch(tmp_path, rebuild=False)
    try:
        # 轮询触发：写入 → 等待越过防抖(2s) → 检查；失败则重试
        # （容忍 observer 监听就绪延迟，且避免写入过快触发防抖饥饿）
        deadline = time.time() + 30
        n = 0
        while time.time() < deadline:
            d = tmp_path / "个人" / "2026-7-15"
            d.mkdir(parents=True, exist_ok=True)
            (d / "日报.md").write_text(MD_DAILY + f"\n- 写入 {int(time.time())}\n", encoding="utf-8")
            time.sleep(4)  # 等待防抖(2s) + 索引执行
            n = _file_count(tmp_path)
            if n >= 1:
                break
        assert n >= 1, "watchdog 应在防抖后自动完成增量索引"
    finally:
        observer.stop()
        observer.join()


def test_watch_rebuild_before_listen(tmp_path, monkeypatch, mock_embed):
    """rebuild=True：启动监听前先全量重建。"""
    d = tmp_path / "小组" / "2026-7-28"
    d.mkdir(parents=True)
    (d / "今日总结.md").write_text("# 今日总结\n- 完成拼房对账模块", encoding="utf-8")

    monkeypatch.setenv("XIAOYU_DATA_DIR", str(tmp_path))
    from sidecar.watch import watch

    observer = watch(tmp_path, rebuild=True)
    try:
        assert _file_count(tmp_path) == 1, "rebuild 应在监听启动前完成全量入库"
    finally:
        observer.stop()
        observer.join()

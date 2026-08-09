"""CLI 标准流编码测试 — 服务器 locale 缺失/终端编码不一致时不崩溃（UTF-8 + errors=replace）"""

import io
import pytest

from kb.Transformer.cli import _ensure_utf8_stdio


class TestEnsureUtf8Stdio:
    """stdin/stdout/stderr 强制 UTF-8，坏字节降级为 � 而非抛 UnicodeDecodeError。"""

    def test_reconfigures_to_utf8(self, monkeypatch):
        """非 UTF-8 编码的 stdin 被重配置为 UTF-8。"""
        fake_stdin = io.TextIOWrapper(io.BytesIO(), encoding="ascii", errors="strict")
        monkeypatch.setattr("sys.stdin", fake_stdin)
        _ensure_utf8_stdio()
        assert fake_stdin.encoding == "utf-8"
        assert fake_stdin.errors == "replace"

    def test_bad_bytes_no_crash(self, monkeypatch):
        """GBK 等坏字节输入：读取不抛 UnicodeDecodeError（降级为 �）。"""
        fake_stdin = io.TextIOWrapper(
            io.BytesIO(b"\xcf\xd6\xb8\xc5\n"), encoding="ascii", errors="strict"
        )
        monkeypatch.setattr("sys.stdin", fake_stdin)
        _ensure_utf8_stdio()

        line = fake_stdin.readline()   # 修复前此处抛 UnicodeDecodeError
        assert line                    # 读取成功，坏字节已降级
        assert "\ufffd" in line        # U+FFFD 替换字符

    def test_valid_utf8_untouched(self, monkeypatch):
        """合法 UTF-8 中文正常读取，内容不丢失。"""
        fake_stdin = io.TextIOWrapper(
            io.BytesIO("现概括已有内容\n".encode("utf-8")),
            encoding="ascii", errors="strict",
        )
        monkeypatch.setattr("sys.stdin", fake_stdin)
        _ensure_utf8_stdio()
        assert fake_stdin.readline().strip() == "现概括已有内容"

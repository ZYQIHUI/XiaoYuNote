""".env 解析单元测试（config.py _load_dotenv）"""

import os
import pytest
from pathlib import Path
from kb.config import _load_dotenv


class TestLoadDotenv:
    """.env 解析：基本赋值、注释、引号、export、不覆盖已有变量。"""

    def test_basic_key_value(self, tmp_path, monkeypatch):
        """基本 KEY=VALUE 解析。"""
        env_file = tmp_path / ".env"
        env_file.write_text("OPENAI_API_KEY=sk-test-123\n", encoding="utf-8")
        monkeypatch.delenv("OPENAI_API_KEY", raising=False)
        _load_dotenv(env_file)
        assert os.environ["OPENAI_API_KEY"] == "sk-test-123"

    def test_skip_comments_and_blank(self, tmp_path, monkeypatch):
        """# 注释行与空行跳过。"""
        env_file = tmp_path / ".env"
        env_file.write_text(
            "# 注释\n\nOPENAI_BASE_URL=https://api.example.com/v1\n",
            encoding="utf-8",
        )
        monkeypatch.delenv("OPENAI_BASE_URL", raising=False)
        _load_dotenv(env_file)
        assert os.environ["OPENAI_BASE_URL"] == "https://api.example.com/v1"

    def test_quoted_value_with_spaces(self, tmp_path, monkeypatch):
        """引号包裹的值（含空格）保留原样。"""
        env_file = tmp_path / ".env"
        env_file.write_text('KB_LOG_LEVEL="DEBUG mode"\n', encoding="utf-8")
        monkeypatch.delenv("KB_LOG_LEVEL", raising=False)
        _load_dotenv(env_file)
        assert os.environ["KB_LOG_LEVEL"] == "DEBUG mode"

    def test_export_prefix(self, tmp_path, monkeypatch):
        """export 前缀支持。"""
        env_file = tmp_path / ".env"
        env_file.write_text("export KB_TIMEOUT=60\n", encoding="utf-8")
        monkeypatch.delenv("KB_TIMEOUT", raising=False)
        _load_dotenv(env_file)
        assert os.environ["KB_TIMEOUT"] == "60"

    def test_inline_comment_stripped(self, tmp_path, monkeypatch):
        """行内注释（空格+#）剥离。"""
        env_file = tmp_path / ".env"
        env_file.write_text("KB_MAX_RETRIES=3 # 重试次数\n", encoding="utf-8")
        monkeypatch.delenv("KB_MAX_RETRIES", raising=False)
        _load_dotenv(env_file)
        assert os.environ["KB_MAX_RETRIES"] == "3"

    def test_existing_env_not_overridden(self, tmp_path, monkeypatch):
        """shell 中已存在的环境变量优先，.env 不覆盖。"""
        env_file = tmp_path / ".env"
        env_file.write_text("KB_LOG_LEVEL=DEBUG\n", encoding="utf-8")
        monkeypatch.setenv("KB_LOG_LEVEL", "INFO")
        _load_dotenv(env_file)
        assert os.environ["KB_LOG_LEVEL"] == "INFO"

    def test_missing_file_no_error(self, tmp_path):
        """.env 不存在时静默跳过。"""
        _load_dotenv(tmp_path / "not_exist.env")  # 不应抛异常

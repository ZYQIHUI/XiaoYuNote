"""XiaoYu 配置管理 — config.toml + 环境变量 + 校验"""

from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


@dataclass
class DataConfig:
    sources: list[str] = field(default_factory=lambda: ["个人", "小组", "文档", "VDMS在线办公平台"])
    exclude_dirs: list[str] = field(default_factory=lambda: [".reasonix", "XiaoYu", "新建文件夹", ".git"])
    exclude_exts: list[str] = field(default_factory=lambda: ["png", "jpeg", "jpg", "mp4", "ofd", "zip", "xmind", "doc", "ini"])
    max_file_mb: int = 50


@dataclass
class ChunkConfig:
    size: int = 600
    overlap_ratio: float = 0.1
    min_size: int = 50


@dataclass
class RetrievalConfig:
    top_k: int = 5
    max_per_file: int = 2
    max_context_chars: int = 6000
    score_threshold: float = 0.0
    enable_bm25: bool = False
    include_null_date: bool = True


@dataclass
class VectorConfig:
    batch_size: int = 32
    dim: int = 1024
    query_instruction: str = ""


@dataclass
class StoreConfig:
    path: str = "data/kb.sqlite3"


@dataclass
class SecurityConfig:
    skip_sensitive_files: bool = True
    sensitive_fields: list[str] = field(default_factory=lambda: ["密码", "password", "secret", "key", "token", "账号", "appid"])


@dataclass
class Config:
    data: DataConfig = field(default_factory=DataConfig)
    chunk: ChunkConfig = field(default_factory=ChunkConfig)
    retrieval: RetrievalConfig = field(default_factory=RetrievalConfig)
    vector: VectorConfig = field(default_factory=VectorConfig)
    store: StoreConfig = field(default_factory=StoreConfig)
    security: SecurityConfig = field(default_factory=SecurityConfig)

    # --- 环境变量（运行时注入） ---
    openai_base_url: str = ""
    openai_api_key: str = ""
    chat_model: str = ""
    embed_model: str = ""
    embed_base_url: Optional[str] = None  # 缺省回落 openai_base_url
    timeout: int = 60
    max_retries: int = 3
    retry_backoff: float = 2.0
    log_level: str = "INFO"

    # 项目根目录（自动检测）
    root_dir: Path = field(default_factory=lambda: Path(__file__).resolve().parent)


def load_config(config_path: Optional[Path] = None) -> Config:
    """加载 config.toml + .env，返回校验后的 Config 对象。"""
    root = Path(__file__).resolve().parent
    cfg_path = config_path or root / "config.toml"

    # 1) 加载 TOML
    raw: dict = {}
    if cfg_path.exists():
        with open(cfg_path, "rb") as f:
            raw = tomllib.load(f)

    # 2) 加载 .env 到环境变量（不覆盖 shell 中已存在的变量）
    _load_dotenv(root / ".env")

    # 3) 构建默认 Config，用 TOML 覆盖
    cfg = Config(root_dir=root)
    _apply_toml(cfg, raw)

    # 4) 环境变量覆盖（优先级最高：shell 环境 > .env > config.toml）
    _apply_env(cfg)

    # 5) 校验
    _validate(cfg)

    return Config(
        data=cfg.data,
        chunk=cfg.chunk,
        retrieval=cfg.retrieval,
        vector=cfg.vector,
        store=cfg.store,
        security=cfg.security,
        openai_base_url=cfg.openai_base_url,
        openai_api_key=cfg.openai_api_key,
        chat_model=cfg.chat_model,
        embed_model=cfg.embed_model,
        embed_base_url=cfg.embed_base_url,
        timeout=cfg.timeout,
        max_retries=cfg.max_retries,
        retry_backoff=cfg.retry_backoff,
        log_level=cfg.log_level,
        root_dir=root,
    )


# ------------------------------------------------------------------
# 内部辅助
# ------------------------------------------------------------------

def _load_dotenv(path: Path) -> None:
    """解析 .env 文件到环境变量（不覆盖已存在的环境变量）。

    支持：KEY=VALUE、export 前缀、单/双引号包裹、# 注释、空行。
    优先级：shell 已有环境变量 > .env > config.toml（.env 兜底填充）。
    """
    if not path.exists():
        return

    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()

        key, sep, value = line.partition("=")
        if not sep:
            continue
        key = key.strip()
        value = value.strip()

        # 去引号（单/双引号包裹）
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        else:
            # 行内注释：空格 + #（引号外）
            hash_idx = value.find(" #")
            if hash_idx != -1:
                value = value[:hash_idx].rstrip()

        if key:
            os.environ.setdefault(key, value)


def _apply_toml(cfg: Config, raw: dict) -> None:
    """将 TOML 字段映射到 Config dataclass。"""
    for section_name, section_data in raw.items():
        section = getattr(cfg, section_name, None)
        if section is None or not hasattr(section, "__dataclass_fields__"):
            continue
        for k, v in section_data.items():
            if k in section.__dataclass_fields__:
                setattr(section, k, v)


def _apply_env(cfg: Config) -> None:
    """环境变量覆盖。"""
    cfg.openai_base_url = os.getenv("OPENAI_BASE_URL", cfg.openai_base_url)
    cfg.openai_api_key = os.getenv("OPENAI_API_KEY", "")
    cfg.chat_model = os.getenv("KB_CHAT_MODEL", cfg.chat_model)
    cfg.embed_model = os.getenv("KB_EMBED_MODEL", cfg.embed_model)
    cfg.embed_base_url = os.getenv("KB_EMBED_BASE_URL", cfg.embed_base_url)
    cfg.timeout = int(os.getenv("KB_TIMEOUT", str(cfg.timeout)))
    cfg.max_retries = int(os.getenv("KB_MAX_RETRIES", str(cfg.max_retries)))
    cfg.retry_backoff = float(os.getenv("KB_RETRY_BACKOFF", str(cfg.retry_backoff)))
    cfg.log_level = os.getenv("KB_LOG_LEVEL", cfg.log_level)


def _validate(cfg: Config) -> None:
    """关键配置校验，不通过则抛出明确错误。"""
    if not cfg.openai_api_key:
        raise ValueError(
            "API key 未设置。请执行:\n"
            "  cp .env.example .env\n"
            "  编辑 .env 填入 OPENAI_API_KEY 和 OPENAI_BASE_URL"
        )
    if not cfg.chat_model:
        raise ValueError("未配置 chat 模型 (KB_CHAT_MODEL)")
    if not cfg.embed_model:
        raise ValueError("未配置 embedding 模型 (KB_EMBED_MODEL)")

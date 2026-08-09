"""XiaoYu 记忆层 — profile.md 个人画像注入（v0.1）"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from pathlib import Path

logger = logging.getLogger("kb.memory")


@dataclass
class Profile:
    """个人画像数据结构。"""
    role: str = ""           # 角色
    goals: list[str] = field(default_factory=list)  # 目标列表
    weaknesses: list[str] = field(default_factory=list)  # 薄弱项
    style: str = "中文，简洁，结论先行"  # 语言风格
    raw_text: str = ""       # 原始 markdown 文本


def load_profile(profile_path: Path | None = None) -> Profile:
    """加载 profile.md 个人画像文件。

    Args:
        profile_path: 文件路径；默认在项目根目录找 profile.md。

    Returns:
        Profile 对象（文件不存在则返回空 Profile）。
    """
    if profile_path is None:
        # 默认位置：项目根目录 / 或 Menmory/
        for candidate in [Path("profile.md"), Path("Menmory/profile.md")]:
            if candidate.exists():
                profile_path = candidate
                break

    if profile_path is None or not profile_path.exists():
        logger.info("未找到 profile.md，记忆层将以空画像运行")
        return Profile()

    text = profile_path.read_text(encoding="utf-8")
    logger.info(f"已加载个人画像: {profile_path}")

    return _parse_profile(text)


def _parse_profile(text: str) -> Profile:
    """解析 profile.md 格式为结构化 Profile。

    支持格式：
    - 角色：xxx
    - 目标：xxx / - xxx
    - 薄弱项：xxx / - xxx
    - 风格：xxx
    """
    role = ""
    goals: list[str] = []
    weaknesses: list[str] = []
    style = "中文，简洁，结论先行"

    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        # 角色行
        if stripped.startswith("- 角色") or stripped.startswith("角色"):
            role = stripped.split("：", 1)[-1].split(":", 1)[-1].strip()

        # 目标行
        elif stripped.startswith("- 目标") or stripped.startswith("目标"):
            val = stripped.split("：", 1)[-1].split(":", 1)[-1].strip()
            if val:
                goals.append(val)

        # 薄弱项行
        elif stripped.startswith("- 薄弱") or stripped.startswith("薄弱"):
            val = stripped.split("：", 1)[-1].split(":", 1)[-1].strip()
            if val:
                weaknesses.append(val)

        # 风格行
        elif stripped.startswith("- 风格") or stripped.startswith("风格"):
            style = stripped.split("：", 1)[-1].split(":", 1)[-1].strip()

        # 列表项（续接上一级）
        elif stripped.startswith("- ") and stripped[2:].strip():
            item = stripped[2:].strip()
            # 根据上下文判断归属（简单启发式）
            if len(goals) > len(weaknesses):
                goals.append(item)
            else:
                weaknesses.append(item)

    return Profile(
        role=role,
        goals=goals,
        weaknesses=weaknesses,
        style=style,
        raw_text=text,
    )


def format_profile_for_prompt(profile: Profile) -> str:
    """将 Profile 格式化为 system prompt 可注入的文本片段。

    Returns:
        空字符串表示无画像；否则返回格式化的画像段落。
    """
    if not profile.role and not profile.goals and not profile.weaknesses:
        return ""

    lines = ["【个人画像】"]
    if profile.role:
        lines.append(f"- 角色：{profile.role}")
    if profile.goals:
        lines.append(f"- 目标：{'；'.join(profile.goals)}")
    if profile.weaknesses:
        lines.append(f"- 薄弱项：{'；'.join(profile.weaknesses)}")
    if profile.style:
        lines.append(f"- 语言风格：{profile.style}")

    return "\n".join(lines)

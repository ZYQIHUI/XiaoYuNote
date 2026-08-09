"""Transformer — 问答链路：检索 → 生成 → CLI"""

from .retriever import Retriever
from .generator import Generator
from .cli import main

__all__ = ["Retriever", "Generator", "main"]

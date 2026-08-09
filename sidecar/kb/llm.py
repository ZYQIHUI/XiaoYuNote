"""XiaoYu LLM 客户端 — OpenAI 兼容 chat / embed 封装"""

from __future__ import annotations

import logging
import time
from typing import Optional

from openai import (
    OpenAI,
    APIError,
    APIConnectionError,
    AuthenticationError,
    RateLimitError as OpenAIRateLimitError,
)
from .config import Config

logger = logging.getLogger("kb.llm")


class NetworkError(Exception):
    """网络错误（可重试）。"""
    pass


class RateLimitError(Exception):
    """限流（退避重试）。"""
    pass


class AuthError(Exception):
    """认证失败（立即停止）。"""
    pass


class ContextError(Exception):
    """上下文超限（截断后重试）。"""
    pass


class LLMClient:
    """OpenAI 兼容客户端封装：chat + embed，带重试、超时、错误分类。"""

    def __init__(self, cfg: Config) -> None:
        self._cfg = cfg
        self._chat_client = OpenAI(
            base_url=cfg.openai_base_url,
            api_key=cfg.openai_api_key,
            timeout=cfg.timeout,
        )
        # embedding 可能走不同 base_url
        embed_base = cfg.embed_base_url or cfg.openai_base_url
        self._embed_client = OpenAI(
            base_url=embed_base,
            api_key=cfg.openai_api_key,
            timeout=cfg.timeout,
        )

    # ------------------------------------------------------------------
    # Chat
    # ------------------------------------------------------------------

    def chat(
        self,
        messages: list[dict],
        temperature: float = 0.3,
    ) -> str:
        """带重试（指数退避）、超时、错误分类的 chat 调用。"""
        last_exc: Optional[Exception] = None
        for attempt in range(self._cfg.max_retries):
            try:
                resp = self._chat_client.chat.completions.create(
                    model=self._cfg.chat_model,
                    messages=messages,
                    temperature=temperature,
                )
                return resp.choices[0].message.content or ""
            except AuthenticationError as e:
                raise AuthError(f"API 认证失败，请检查 OPENAI_API_KEY: {e}") from e
            except OpenAIRateLimitError as e:
                last_exc = RateLimitError(f"限流 (attempt {attempt+1}/{self._cfg.max_retries}): {e}")
                logger.warning(str(last_exc))
                time.sleep(self._cfg.retry_backoff ** (attempt + 1))
            except (APIConnectionError, APIError) as e:
                last_exc = NetworkError(f"网络/API 错误 (attempt {attempt+1}/{self._cfg.max_retries}): {e}")
                logger.warning(str(last_exc))
                time.sleep(self._cfg.retry_backoff ** (attempt + 1))

        raise last_exc or RuntimeError("chat 重试耗尽")

    # ------------------------------------------------------------------
    # Embedding
    # ------------------------------------------------------------------

    def embed(self, texts: list[str]) -> list[list[float]]:
        """批量 embedding；单条超长时自动截断到模型上限；返回与输入等长列表。"""
        if not texts:
            return []

        results: list[list[float]] = []
        batch_size = self._cfg.vector.batch_size

        for i in range(0, len(texts), batch_size):
            batch = texts[i : i + batch_size]
            vectors = self._embed_batch(batch)
            results.extend(vectors)

        return results

    def embed_one(self, text: str) -> list[float]:
        """单条文本向量化。"""
        result = self.embed([text])
        return result[0] if result else []

    # ------------------------------------------------------------------
    # 内部
    # ------------------------------------------------------------------

    def _embed_batch(self, texts: list[str]) -> list[list[float]]:
        """单批 embedding 调用，带重试和维度校验。"""
        last_exc: Optional[Exception] = None
        for attempt in range(self._cfg.max_retries):
            try:
                resp = self._embed_client.embeddings.create(
                    model=self._cfg.embed_model,
                    input=texts,
                )
                vectors = [d.embedding for d in resp.data]

                # 首批维度校验 (r1 P2.14)
                if vectors and len(vectors[0]) != self._cfg.vector.dim:
                    raise ValueError(
                        f"向量维度不匹配: 模型输出 {len(vectors[0])}D, "
                        f"配置期望 {self._cfg.vector.dim}D。"
                        f"请检查 [vector].dim 或执行 kb reset"
                    )
                return vectors
            except AuthenticationError as e:
                raise AuthError(f"Embedding API 认证失败: {e}") from e
            except OpenAIRateLimitError as e:
                last_exc = RateLimitError(f"Embedding 限流 (attempt {attempt+1}): {e}")
                logger.warning(str(last_exc))
                time.sleep(self._cfg.retry_backoff ** (attempt + 1))
            except (APIConnectionError, APIError) as e:
                last_exc = NetworkError(f"Embedding 网络/API 错误 (attempt {attempt+1}): {e}")
                logger.warning(str(last_exc))
                time.sleep(self._cfg.retry_backoff ** (attempt + 1))

        raise last_exc or RuntimeError("embedding 重试耗尽")

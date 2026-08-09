"""XiaoYu CLI — click 命令：config / scan / index / ask / stats / prune / reset（r1 第 11 节）"""

from __future__ import annotations

import click
import sys
from datetime import date
from pathlib import Path
from typing import Optional

from ..config import Config, load_config
from ..utils import setup_logging


def _ensure_utf8_stdio() -> None:
    """将 stdin/stdout/stderr 统一为 UTF-8（errors=replace）。

    服务器 locale 缺失或终端编码不一致（如 SSH 客户端发 GBK 字节）时，
    避免 input() 中文输入抛 UnicodeDecodeError 崩溃；坏字节降级为 �。
    """
    for stream in (sys.stdin, sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            try:
                reconfigure(encoding="utf-8", errors="replace")
            except (ValueError, OSError):
                pass


@click.group()
@click.option("--config-file", default=None, type=click.Path(exists=True), help="配置文件路径")
@click.pass_context
def main(ctx: click.Context, config_file: Optional[str]) -> None:
    """XiaoYu — 伴随成长的个人工作知识库 Agent"""
    _ensure_utf8_stdio()
    ctx.ensure_object(dict)
    cfg = load_config(Path(config_file) if config_file else None)
    setup_logging(cfg.log_level, cfg.root_dir / "data" / "logs")
    ctx.obj["cfg"] = cfg


@main.command()
@click.pass_context
def config_cmd(ctx: click.Context) -> None:
    """打印生效配置（隐藏 key 中间段）"""
    cfg: Config = ctx.obj["cfg"]
    key = cfg.openai_api_key
    masked = f"{key[:6]}...{key[-4:]}" if len(key) > 10 else "***"
    click.echo(f"=== XiaoYu 配置 ===")
    click.echo(f"数据源: {cfg.data.sources}")
    click.echo(f"Chat 模型: {cfg.chat_model}")
    click.echo(f"Embedding 模型: {cfg.embed_model}")
    click.echo(f"API Base URL: {cfg.openai_base_url}")
    click.echo(f"API Key: {masked}")
    click.echo(f"向量维度: {cfg.vector.dim}")
    click.echo(f"Top-K: {cfg.retrieval.top_k}")
    click.echo(f"每文件上限: {cfg.retrieval.max_per_file}")
    click.echo(f"上下文预算: {cfg.retrieval.max_context_chars} 字符")


@main.command()
@click.option("--dry-run", is_flag=True, help="仅统计，不实际入库")
@click.option("--source", default=None, help="只索引指定源（如 个人）")
@click.pass_context
def scan(ctx: click.Context, dry_run: bool, source: Optional[str]) -> None:
    """扫描统计：各格式文件数/预计块数/跳过数/敏感文件数"""
    cfg: Config = ctx.obj["cfg"]
    from ..QA.scanner import scan as do_scan

    result = do_scan(cfg, dry_run=dry_run, source=source)

    click.echo("\n=== 扫描结果 ===")
    click.echo(f"新增文件:   {len(result.new_files)}")
    click.echo(f"变更文件:   {len(result.changed_files)}")
    click.echo(f"跳过(未变): {len(result.skipped_files)}")
    click.echo(f"排除(黑名单): {len(result.excluded_files)}")
    click.echo(f"敏感文件:   {len(result.sensitive_files)}")
    click.echo(f"已删除残留: {len(result.deleted_rel_paths)}")

    if result.error_files:
        click.echo(f"\n⚠️ 解析错误 ({len(result.error_files)}):")
        for p, err in result.error_files[:5]:
            click.echo(f"  - {p}: {err}")

    if not dry_run and (result.new_files or result.changed_files):
        click.echo(f"\n💡 运行 `kb index` 开始入库")


@main.command()
@click.option("--source", default=None, help="只索引指定源")
@click.option("--force", is_flag=True, help="忽略哈希/mtime 强制全量重建")
@click.pass_context
def index(ctx: click.Context, source: Optional[str], force: bool) -> None:
    """全链路建库（扫描→解析→切块→向量化→入库，进度条）"""
    cfg: Config = ctx.obj["cfg"]

    # 换模型防护 (r1 P0.4)
    from ..QA.store import Store
    store = Store(cfg)
    if not force and not store.check_embedding_model(cfg.embed_model):
        click.secho(
            f"⚠️ Embedding 模型不匹配！\n"
            f"  库中记录: {store.get_meta('embedding_model')}\n"
            f"  当前配置: {cfg.embed_model}\n"
            f"  请执行 `kb reset --yes` 后重新建库，或使用 --force 强制覆盖",
            fg="red",
        )
        raise SystemExit(1)

    # 文件删除同步 (r1 P2.12)
    from ..QA.scanner import scan as do_scan
    result = do_scan(cfg, dry_run=False, source=source)
    store.prune_deleted({p.relative_to(cfg.root_dir).as_posix() for p in (result.new_files + result.changed_files + result.skipped_files)})

    # 全链路入库
    all_docs = _parse_all(result.new_files + result.changed_files, cfg)
    if not all_docs:
        click.echo("✅ 无需入库的内容")
        return

    # 写真实文件记录（hash/size/mtime），恢复增量判重（r1 P2.1）
    _record_files(store, all_docs, cfg)

    from ..QA.chunker import chunk_documents
    chunks = chunk_documents(all_docs, cfg)
    click.echo(f"共生成 {len(chunks)} 个 chunk")

    from ..QA.embedder import embed_and_store
    stats = embed_and_store(chunks, cfg, store)
    click.echo(
        f"✅ 入库完成: ok={stats['ok']}, failed={stats['failed']}"
    )


@main.command()
@click.argument("query", nargs=-1, required=False)
@click.pass_context
def ask(ctx: click.Context, query: tuple[str]) -> None:
    """进入一问一答循环（也可带参数直接问一次）"""
    cfg: Config = ctx.obj["cfg"]

    from .retriever import Retriever
    from .generator import Generator
    from ..Menmory.memory import load_profile, format_profile_for_prompt

    retriever = Retriever(cfg)
    generator = Generator(cfg)
    profile_text = format_profile_for_prompt(load_profile(cfg.root_dir / "profile.md"))

    def do_ask(q: str):
        chunks = retriever.topk(q)
        answer, refs = generator.generate(q, chunks, profile_text, str(date.today()))
        click.echo(f"\nXiaoYu：{answer}\n")
        if refs:
            click.echo("引用：")
            for r in refs:
                src = r["source"]
                dt = r.get("date", "")
                extra = ""
                if "rows" in r:
                    extra = f" 行={r['rows']}"
                elif "heading" in r:
                    extra = f" 标题={r['heading']}"
                click.echo(f"  [{r['index']}] {src}（{dt}{extra}）")

    if query:
        do_ask(" ".join(query))
        return

    # 交互循环
    click.echo("🤖 XiaoYu 知识库问答（输入问题，/quit 退出）")
    while True:
        try:
            q = input("你：").strip()
        except (EOFError, KeyboardInterrupt):
            break

        if not q:
            continue
        if q.lower() in ("/quit", "/exit"):
            break
        if q.startswith("/help"):
            _print_help()
            continue
        do_ask(q)


@main.command()
@click.pass_context
def stats(ctx: click.Context) -> None:
    """库统计：文件数/块数/按类型与日期分布"""
    cfg: Config = ctx.obj["cfg"]
    from ..QA.store import Store
    store = Store(cfg)
    s = store.stats()

    click.echo("=== 库统计 ===")
    click.echo(f"文件总数: {s['files']}")
    click.echo(f"Chunk 总数: {s['chunks']}")

    if s["by_type"]:
        click.echo("\n按类型:")
        for t, c in sorted(s["by_type"].items()):
            click.echo(f"  {t}: {c}")

    if s["by_status"]:
        click.echo("\n按状态:")
        for st, c in sorted(s["by_status"].items()):
            click.echo(f"  {st}: {c}")


@main.command()
@click.pass_context
def prune(ctx: click.Context) -> None:
    """清理已删除文件的残留 chunks"""
    cfg: Config = ctx.obj["cfg"]
    from ..QA.store import Store
    from ..QA.scanner import scan as do_scan

    store = Store(cfg)
    result = do_scan(cfg, dry_run=True)
    deleted = store.prune_deleted({
        p.relative_to(cfg.root_dir).as_posix()
        for p in (result.new_files + result.changed_files + result.skipped_files)
    })
    if deleted:
        click.echo(f"✅ 已清理 {len(deleted)} 个已删除文件的残留记录")
        for d in deleted:
            click.echo(f"  - {d}")
    else:
        click.echo("✅ 无需清理的残留记录")


@main.command()
@click.option("--yes", "-y", is_flag=True, help="跳过确认")
@click.pass_context
def reset(ctx: click.Context, yes: bool) -> None:
    """清空向量库（重建用）"""
    if not yes:
        if not click.confirm("⚠️ 确认清空向量库？此操作不可撤销！"):
            click.echo("已取消")
            return

    cfg: Config = ctx.obj["cfg"]
    from ..QA.store import Store
    store = Store(cfg)
    store.reset()
    click.echo("✅ 向量库已清空")


# ------------------------------------------------------------------
# 内部辅助
# ------------------------------------------------------------------

def _record_files(store, docs: list, cfg: Config) -> None:
    """为解析出的文档写 files 表真实记录（hash/size/mtime），恢复增量判重。"""
    from datetime import datetime

    from ..models import FileRecord
    from ..utils import file_sha256

    by_path: dict[str, object] = {}
    for d in docs:
        by_path.setdefault(d.rel_path, d)

    now = datetime.now().isoformat()
    for rel, doc in by_path.items():
        fpath = Path(doc.path)
        stat = fpath.stat()
        store.upsert_file(FileRecord(
            rel_path=rel,
            file_hash=file_sha256(fpath),
            size_bytes=stat.st_size,
            mtime_ns=stat.st_mtime_ns,
            date=doc.date,
            date_source=doc.date_source,
            parsed_at=now,
            status="ok",
        ))


def _parse_all(file_paths: list[Path], cfg: Config) -> list:
    """对文件列表执行解析。"""
    from ..QA.parsers import get_parser
    from ..models import Document

    all_docs: list[Document] = []
    for fpath in file_paths:
        ext = fpath.suffix.lower()
        parser_fn = get_parser(ext)
        if parser_fn is None:
            continue
        try:
            docs = parser_fn(fpath, cfg)
            all_docs.extend(docs)
        except Exception as e:
            click.secho(f"解析失败: {fpath.name} — {e}", fg="yellow")
    return all_docs


def _print_help() -> None:
    click.echo("""
可用命令：
  直接输入          提问
  /date YYYYMMDD YYYYMMDD  设置日期范围过滤
  /type excel      来源类型过滤
  /path 小组        路径前缀过滤
  /topk 8           调整检索条数
  /ref              重看上一轮引用列表
  /profile          查看当前注入的个人画像
  /help             帮助
  /quit             退出
""")


if __name__ == "__main__":
    main()

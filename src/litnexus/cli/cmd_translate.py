from __future__ import annotations
import asyncio
from pathlib import Path
from typing import Annotated, Optional
import typer
from litnexus.core.config import load_config, get_api_key, ConfigError
from litnexus.core import db as db_mod
from litnexus.core import translator as trans_mod

def translate(
    batch_size: Annotated[Optional[int], typer.Option(help="覆盖每批翻译数量")] = None,
    concurrency: Annotated[Optional[int], typer.Option(help="覆盖并发数")] = None,
    dry_run: Annotated[bool, typer.Option("--dry-run", help="只显示待翻译数量，不调用 API")] = False,
    config: Annotated[Optional[Path], typer.Option(help="config.toml 路径")] = None,
    yes: Annotated[bool, typer.Option("--yes", "-y", help="跳过确认")] = False,
):
    """批量翻译数据库中尚未翻译的文章标题。"""
    try:
        cfg = load_config(config)
        api_key = get_api_key(cfg)
    except ConfigError as e:
        typer.echo(f"配置错误：{e}", err=True)
        raise typer.Exit(1)

    if batch_size:
        cfg.translate.batch_size = batch_size
    if concurrency:
        cfg.translate.concurrency = concurrency
    cfg.ai.api_key = api_key

    conn = db_mod.get_connection(cfg.paths.db)
    try:
        pending = db_mod.fetch_pending_translations(conn)
        typer.echo(f"待翻译：{len(pending)} 篇（批量大小 {cfg.translate.batch_size}）")
        if dry_run or not pending:
            return
        if not yes:
            typer.confirm("确认开始翻译？", abort=True)
        translated, failed = asyncio.run(
            trans_mod.run_translation(conn, cfg.translate, cfg.ai)
        )
        typer.echo(f"\n翻译完成：成功 {translated}，失败 {failed}")
    finally:
        conn.close()

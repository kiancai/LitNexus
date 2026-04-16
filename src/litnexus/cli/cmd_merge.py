from __future__ import annotations
from pathlib import Path
from typing import Annotated, Optional
import typer
from litnexus.core.config import load_config, ConfigError
from litnexus.core import db as db_mod
from litnexus.core.io import iter_jsonl, parse_article

def merge(
    input_dir: Annotated[Optional[Path], typer.Option(help="JSONL 目录（默认读 config paths.download_dir）")] = None,
    config: Annotated[Optional[Path], typer.Option(help="config.toml 路径")] = None,
):
    """将 download/ 目录下的 JSONL 文件合并入 SQLite 数据库。"""
    try:
        cfg = load_config(config)
    except ConfigError as e:
        typer.echo(f"配置错误：{e}", err=True)
        raise typer.Exit(1)

    src_dir = input_dir or cfg.paths.download_dir
    if not src_dir.is_dir():
        typer.echo(f"目录不存在：{src_dir}", err=True)
        raise typer.Exit(1)

    jsonl_files = sorted(src_dir.glob("*.jsonl"))
    if not jsonl_files:
        typer.echo(f"未找到 .jsonl 文件：{src_dir}")
        return

    conn = db_mod.get_connection(cfg.paths.db)
    total_inserted = total_skipped = total_errors = 0

    try:
        for fpath in jsonl_files:
            typer.echo(f"处理：{fpath.name}")
            batch = []
            errors = 0
            for raw in iter_jsonl(fpath):
                parsed = parse_article(raw)
                if not parsed.get("epmc_id"):
                    errors += 1
                    continue
                batch.append(parsed)
            inserted, skipped = db_mod.insert_articles(conn, batch)
            typer.echo(f"  插入 {inserted}，跳过（重复）{skipped}，错误 {errors}")
            total_inserted += inserted
            total_skipped += skipped
            total_errors += errors
    finally:
        conn.close()

    typer.echo(f"\n合并完成：插入 {total_inserted}，跳过 {total_skipped}，错误 {total_errors}")

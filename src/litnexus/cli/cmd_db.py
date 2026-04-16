from __future__ import annotations
from pathlib import Path
from typing import Annotated, Optional
import typer
from litnexus.core.config import load_config, ConfigError
from litnexus.core import db as db_mod

def stats(
    config: Annotated[Optional[Path], typer.Option(help="config.toml 路径")] = None,
):
    """显示数据库统计信息。"""
    try:
        cfg = load_config(config)
    except ConfigError as e:
        typer.echo(f"配置错误：{e}", err=True)
        raise typer.Exit(1)

    if not cfg.paths.db.exists():
        typer.echo(f"数据库不存在：{cfg.paths.db}", err=True)
        raise typer.Exit(1)

    conn = db_mod.get_connection(cfg.paths.db)
    try:
        s = db_mod.get_stats(conn)
        typer.echo(f"数据库：{cfg.paths.db}")
        typer.echo(f"  总文章数：          {s['total']}")
        typer.echo(f"  待翻译（无 title_zh）：{s['pending_translation']}")
        typer.echo(f"  待分类（无 q1_ans）：  {s['pending_classification']}")
        typer.echo(f"  已标记 include=yes：  {s['reviewed_yes']}")
        typer.echo(f"  已标记 include=no：   {s['reviewed_no']}")
    finally:
        conn.close()


def migrate(
    config: Annotated[Optional[Path], typer.Option(help="config.toml 路径")] = None,
):
    """手动触发数据库 schema 迁移。"""
    try:
        cfg = load_config(config)
    except ConfigError as e:
        typer.echo(f"配置错误：{e}", err=True)
        raise typer.Exit(1)

    conn = db_mod.get_connection(cfg.paths.db)
    try:
        db_mod.run_migrations(conn, cfg.paths.db)
        typer.echo("迁移完成。")
    finally:
        conn.close()


def backup(
    config: Annotated[Optional[Path], typer.Option(help="config.toml 路径")] = None,
):
    """备份数据库文件。"""
    try:
        cfg = load_config(config)
    except ConfigError as e:
        typer.echo(f"配置错误：{e}", err=True)
        raise typer.Exit(1)

    if not cfg.paths.db.exists():
        typer.echo(f"数据库不存在：{cfg.paths.db}", err=True)
        raise typer.Exit(1)

    bak = db_mod.backup(cfg.paths.db)
    typer.echo(f"已备份到：{bak}")

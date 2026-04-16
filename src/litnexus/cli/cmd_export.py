from __future__ import annotations
import datetime
from pathlib import Path
from typing import Annotated, Optional
import typer
from litnexus.core.config import load_config, ConfigError
from litnexus.core import db as db_mod
from litnexus.core.io import export_to_csv

def export(
    filter: Annotated[Optional[str], typer.Option(help="pending | all | 自定义 SQL WHERE")] = None,
    output: Annotated[Optional[Path], typer.Option(help="输出 CSV 路径")] = None,
    config: Annotated[Optional[Path], typer.Option(help="config.toml 路径")] = None,
):
    """从数据库导出文章到 CSV 文件。"""
    try:
        cfg = load_config(config)
    except ConfigError as e:
        typer.echo(f"配置错误：{e}", err=True)
        raise typer.Exit(1)

    filter_mode = filter or cfg.export.filter
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    out_path = output or (cfg.paths.export_dir / f"articles_{timestamp}.csv")

    conn = db_mod.get_connection(cfg.paths.db)
    try:
        df = db_mod.fetch_for_export(conn, filter_mode)
        if df.empty:
            typer.echo("查询结果为空，未创建 CSV 文件。")
            return
        n = export_to_csv(df, out_path, cfg.export.exclude_columns)
        typer.echo(f"已导出 {n} 篇文章 → {out_path}")
    finally:
        conn.close()

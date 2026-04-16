from __future__ import annotations
from pathlib import Path
from typing import Annotated, Optional
import pandas as pd
import typer
from litnexus.core.config import load_config, ConfigError
from litnexus.core import db as db_mod
from litnexus.core.io import normalize_value

def sync(
    input: Annotated[Optional[Path], typer.Option(help="输入 CSV（默认用 export_dir 下最新 analyzed 文件）")] = None,
    config: Annotated[Optional[Path], typer.Option(help="config.toml 路径")] = None,
):
    """将 CSV 中的分析结果回写到数据库。"""
    try:
        cfg = load_config(config)
    except ConfigError as e:
        typer.echo(f"配置错误：{e}", err=True)
        raise typer.Exit(1)

    if input is None:
        export_dir = cfg.paths.export_dir
        analyzed = sorted(export_dir.glob("articles_analyzed_*.csv"), reverse=True)
        if not analyzed:
            typer.echo(f"在 {export_dir} 中未找到 analyzed CSV，请先运行 litnexus ask", err=True)
            raise typer.Exit(1)
        input = analyzed[0]
        typer.echo(f"使用最新分析文件：{input.name}")

    df = pd.read_csv(input)
    if "epmc_id" not in df.columns:
        typer.echo("CSV 中缺少 epmc_id 列", err=True)
        raise typer.Exit(1)

    updates = []
    for _, row in df.iterrows():
        epmc_id = normalize_value(row.get("epmc_id"))
        if not epmc_id:
            continue
        updates.append({
            "epmc_id": epmc_id,
            "tags":    normalize_value(row.get("tags")),
            "include": normalize_value(row.get("include")),
            "q1_ans":  normalize_value(row.get("q1_ans")),
            "q1_rea":  normalize_value(row.get("q1_rea")),
            "q2_ans":  normalize_value(row.get("q2_ans")),
            "q2_rea":  normalize_value(row.get("q2_rea")),
        })

    conn = db_mod.get_connection(cfg.paths.db)
    try:
        updated = db_mod.update_classifications(conn, updates)
        typer.echo(f"回写完成：输入 {len(df)} 行，更新 {updated} 行")
    finally:
        conn.close()

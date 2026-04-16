from __future__ import annotations
from pathlib import Path
from typing import Annotated, Optional
import typer
from litnexus.core.config import load_config, get_api_key, ConfigError
from litnexus.core import db as db_mod
from litnexus.core import classifier as cls_mod

def ask(
    workers: Annotated[Optional[int], typer.Option(help="覆盖并发线程数")] = None,
    config: Annotated[Optional[Path], typer.Option(help="config.toml 路径")] = None,
):
    """用 AI 对数据库中未分类的文章做多问题分类（直接读写 DB）。"""
    try:
        cfg = load_config(config)
        api_key = get_api_key(cfg)
    except ConfigError as e:
        typer.echo(f"配置错误：{e}", err=True)
        raise typer.Exit(1)

    cfg.ai.api_key = api_key
    if workers:
        cfg.classify.max_workers = workers

    # 确保动态列存在
    conn = db_mod.get_connection(cfg.paths.db, cfg)
    conn.close()

    if not cfg.classify.questions:
        typer.echo("配置中未定义任何问题（classify.questions 为空）", err=True)
        raise typer.Exit(1)

    q_ids = ", ".join(q.id for q in cfg.classify.questions)
    typer.echo(f"问题列表：{q_ids}")

    processed, failed = cls_mod.run_classification(cfg.paths.db, cfg.classify, cfg.ai)
    typer.echo(f"\n分类完成：处理 {processed}，失败 {failed}")

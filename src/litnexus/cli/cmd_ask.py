from __future__ import annotations
import datetime
from pathlib import Path
from typing import Annotated, Optional
import typer
from litnexus.core.config import load_config, get_api_key, ConfigError
from litnexus.core import classifier as cls_mod

def ask(
    input: Annotated[Optional[Path], typer.Option(help="输入 CSV（默认用 export_dir 下最新文件）")] = None,
    output: Annotated[Optional[Path], typer.Option(help="输出 CSV")] = None,
    workers: Annotated[Optional[int], typer.Option(help="覆盖并发线程数")] = None,
    config: Annotated[Optional[Path], typer.Option(help="config.toml 路径")] = None,
):
    """用 AI 对 CSV 中的文章做双问题分类。"""
    try:
        cfg = load_config(config)
        api_key = get_api_key(cfg)
    except ConfigError as e:
        typer.echo(f"配置错误：{e}", err=True)
        raise typer.Exit(1)

    cfg.ai.api_key = api_key
    if workers:
        cfg.classify.max_workers = workers

    # 找到最新的导出文件
    if input is None:
        export_dir = cfg.paths.export_dir
        csvs = sorted(export_dir.glob("articles_*.csv"), reverse=True)
        if not csvs:
            typer.echo(f"在 {export_dir} 中未找到导出文件，请先运行 litnexus export", err=True)
            raise typer.Exit(1)
        input = csvs[0]
        typer.echo(f"使用最新导出文件：{input.name}")

    if output is None:
        timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        output = input.parent / f"articles_analyzed_{timestamp}.csv"

    processed, skipped = cls_mod.run_classification(input, output, cfg.classify, cfg.ai)
    typer.echo(f"\n分类完成：处理 {processed}，跳过 {skipped} → {output}")

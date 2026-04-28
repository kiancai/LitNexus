from __future__ import annotations
from pathlib import Path
from typing import Annotated, Optional
import typer
from litnexus.core.config import load_config, ConfigError
from litnexus.core import epmc as epmc_mod

def download(
    mode: Annotated[str, typer.Option(help="journals | keywords | all")] = "all",
    days: Annotated[Optional[int], typer.Option(help="覆盖 config 中的 days")] = None,
    output_dir: Annotated[Optional[Path], typer.Option(help="覆盖下载目录")] = None,
    config: Annotated[Optional[Path], typer.Option(help="config.toml 路径")] = None,
    yes: Annotated[bool, typer.Option("--yes", "-y", help="跳过确认")] = False,
):
    """从 Europe PMC 下载文章到 JSONL 文件。"""
    try:
        cfg = load_config(config)
    except ConfigError as e:
        typer.echo(f"配置错误：{e}", err=True)
        raise typer.Exit(1)

    days_val = days or cfg.download.days
    out_dir = output_dir or cfg.paths.download_dir
    typer.echo(f"下载模式：{mode}")
    typer.echo(f"时间范围：最近 {days_val} 天")
    typer.echo(f"输出目录：{out_dir}")
    if not yes:
        typer.confirm("确认开始下载？", abort=True)

    files = epmc_mod.run_download(cfg, out_dir, mode=mode, days=days)
    typer.echo(f"\n下载完成，生成 {len(files)} 个文件。")

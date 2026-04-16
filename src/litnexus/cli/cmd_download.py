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
):
    """从 Europe PMC 下载文章到 JSONL 文件。"""
    try:
        cfg = load_config(config)
    except ConfigError as e:
        typer.echo(f"配置错误：{e}", err=True)
        raise typer.Exit(1)

    out_dir = output_dir or cfg.paths.download_dir
    files = epmc_mod.run_download(cfg, out_dir, mode=mode, days=days)
    typer.echo(f"\n下载完成，生成 {len(files)} 个文件。")

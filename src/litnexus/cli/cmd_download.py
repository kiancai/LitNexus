from __future__ import annotations

from typing import Annotated

import typer

from litnexus.cli import context as ctx
from litnexus.cli import ui
from litnexus.cli.options import (
    DownloadMode,
    DownloadModeOption,
    WorkspaceOption,
    YesOption,
)
from litnexus.core import epmc as epmc_mod
from litnexus.core.config import ConfigError
from litnexus.core.workspace import WorkspaceError

WS_NEXT_STEP = "用 `litnexus init <目录>` 创建工作区，或用 --workspace 指定。"


def download(
    mode: DownloadModeOption = DownloadMode.all,
    days: Annotated[int | None, typer.Option(help="覆盖 config 中的 days")] = None,
    workspace: WorkspaceOption = None,
    yes: YesOption = False,
):
    """从 Europe PMC 下载文章到工作区的 downloads/ 目录。"""
    try:
        ws, cfg = ctx.load(workspace)
    except (WorkspaceError, ConfigError) as e:
        ui.error("无法加载工作区", detail=str(e), next_step=WS_NEXT_STEP)
        raise typer.Exit(1)

    mode_value = mode.value if isinstance(mode, DownloadMode) else str(mode)
    days_val = days or cfg.download.days
    ui.key_values(
        "下载任务",
        [
            ("模式", mode_value),
            ("时间范围", f"最近 {days_val} 天"),
            ("输出目录", ws.downloads_dir),
        ],
    )
    if not yes:
        ui.confirm("确认开始下载？")

    with ui.progress() as reporter:
        files = epmc_mod.run_download(cfg, ws, mode=mode_value, days=days, reporter=reporter)
    ui.success(f"下载完成，生成 {len(files)} 个文件。")
    if files:
        ui.summary_table("生成文件", ["文件", "路径"], [(f.name, f) for f in files])
    return ui.result(
        "download",
        "ok",
        mode=mode_value,
        days=days_val,
        output_dir=ws.downloads_dir,
        files=[{"name": f.name, "path": f} for f in files],
        count=len(files),
    )

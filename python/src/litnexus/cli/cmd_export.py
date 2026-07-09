from __future__ import annotations

import datetime
import sqlite3
from pathlib import Path
from typing import Annotated

import typer

from litnexus.cli import context as ctx
from litnexus.cli import ui
from litnexus.cli.options import WorkspaceOption, YesOption
from litnexus.core import db as db_mod
from litnexus.core import pipeline as pipeline_mod
from litnexus.core.config import ConfigError
from litnexus.core.workspace import WorkspaceError

WS_NEXT_STEP = "用 `litnexus init <目录>` 创建工作区，或用 --workspace 指定。"


def export(
    filter: Annotated[
        str | None,
        typer.Option("--where", "--filter", help="pending | all | 自定义 SQL WHERE"),
    ] = None,
    output: Annotated[Path | None, typer.Option("--output", "-o", help="输出 CSV 路径")] = None,
    workspace: WorkspaceOption = None,
    yes: YesOption = False,
):
    """从数据库导出文章到 CSV 文件（默认存入工作区 exports/）。"""
    try:
        ws, cfg = ctx.load(workspace)
    except (WorkspaceError, ConfigError) as e:
        ui.error("无法加载工作区", detail=str(e), next_step=WS_NEXT_STEP)
        raise typer.Exit(1)

    filter_mode = filter or cfg.export.filter
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    out_path = output or (ws.exports_dir / f"articles_{timestamp}.csv")

    ui.key_values(
        "导出任务",
        [
            ("筛选条件", filter_mode),
            ("输出路径", out_path),
        ],
    )
    if not yes:
        ui.confirm("确认导出？")

    try:
        conn = db_mod.get_connection(ws.db_path, cfg)
    except (OSError, sqlite3.Error) as e:
        ui.error(
            "数据库无法打开",
            detail=str(e),
            next_step="先运行 `litnexus merge`，或用 --workspace 指定可写工作区。",
        )
        raise typer.Exit(1)
    try:
        try:
            n = pipeline_mod.export_articles(conn, cfg, filter_mode, out_path)
        except ValueError as e:
            ui.error(
                "导出筛选无法执行",
                detail=str(e),
                next_step="改用 `--where all`，或在 [schema].custom_columns 中保留 include。",
            )
            raise typer.Exit(1)
        if n == 0:
            ui.warning("查询结果为空，未创建 CSV 文件。")
            return ui.result(
                "export",
                "empty",
                filter=filter_mode,
                output=out_path,
                exported=0,
                created=False,
            )
        ui.success(f"已导出 {n} 篇文章。")
        ui.key_values("导出结果", [("CSV", out_path)])
        return ui.result(
            "export",
            "ok",
            filter=filter_mode,
            output=out_path,
            exported=n,
            created=True,
        )
    finally:
        conn.close()

from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Annotated

import typer

from litnexus.cli import context as ctx
from litnexus.cli import ui
from litnexus.cli.options import WorkspaceOption, YesOption
from litnexus.core import db as db_mod
from litnexus.core import io as io_mod
from litnexus.core.config import ConfigError
from litnexus.core.workspace import WorkspaceError

WS_NEXT_STEP = "用 `litnexus init <目录>` 创建工作区，或用 --workspace 指定。"


def import_csv(
    csv_path: Annotated[Path, typer.Argument(help="编辑过的复筛 CSV 文件路径")],
    workspace: WorkspaceOption = None,
    yes: YesOption = False,
):
    """把编辑过的 CSV 复筛结果（include 等标注列）导回数据库。"""
    try:
        ws, cfg = ctx.load(workspace)
    except (WorkspaceError, ConfigError) as e:
        ui.error("无法加载工作区", detail=str(e), next_step=WS_NEXT_STEP)
        raise typer.Exit(1)

    if not csv_path.exists():
        ui.error(
            "CSV 文件不存在",
            detail=str(csv_path),
            next_step="检查路径，或先用 `litnexus export` 导出。",
        )
        raise typer.Exit(1)

    ann_cols = cfg.schema_cfg.custom_columns
    ui.key_values(
        "导入任务",
        [
            ("CSV", csv_path),
            ("数据库", ws.db_path),
            ("写回标注列", ", ".join(ann_cols)),
        ],
    )
    if not yes:
        ui.confirm("确认把 CSV 标注写回数据库？")

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
        updated, unmatched, total = io_mod.import_reviewed_csv(conn, csv_path, ann_cols)
    except (ValueError, OSError) as e:
        ui.error(
            "CSV 解析失败",
            detail=str(e),
            next_step="确认这是 `litnexus export` 导出的 CSV（含 epmc_id 列）。",
        )
        raise typer.Exit(1)
    finally:
        conn.close()

    ui.success(f"导入完成：更新 {updated} 篇，未匹配 {unmatched} 篇（共 {total} 行）。")
    return ui.result(
        "import",
        "ok",
        csv=csv_path,
        updated=updated,
        unmatched=unmatched,
        total=total,
    )

from __future__ import annotations

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


def merge(
    input_dir: Annotated[
        Path | None,
        typer.Option("--input-dir", "-i", help="JSONL 目录（默认工作区 downloads/）"),
    ] = None,
    workspace: WorkspaceOption = None,
    yes: YesOption = False,
):
    """将工作区 downloads/ 下的 JSONL 文件合并入 SQLite 数据库。"""
    try:
        ws, cfg = ctx.load(workspace)
    except (WorkspaceError, ConfigError) as e:
        ui.error("无法加载工作区", detail=str(e), next_step=WS_NEXT_STEP)
        raise typer.Exit(1)

    src_dir = input_dir or ws.downloads_dir
    if not src_dir.is_dir():
        ui.error(
            "下载目录不存在",
            detail=str(src_dir),
            next_step="先运行 `litnexus download`，或用 --input-dir 指定 JSONL 目录。",
        )
        raise typer.Exit(1)

    jsonl_files = sorted(src_dir.glob("*.jsonl"))
    if not jsonl_files:
        ui.warning(f"未找到 .jsonl 文件：{src_dir}")
        return ui.result(
            "merge",
            "empty",
            input_dir=src_dir,
            database=ws.db_path,
            files=[],
            inserted=0,
            skipped=0,
            errors=0,
        )

    ui.key_values(
        "合并任务",
        [
            ("JSONL 文件", len(jsonl_files)),
            ("输入目录", src_dir),
            ("目标数据库", ws.db_path),
        ],
    )
    ui.summary_table(
        "待合并文件",
        ["文件名", "大小"],
        [(f.name, f"{f.stat().st_size / 1024:.1f} KB") for f in jsonl_files],
    )
    if not yes:
        ui.confirm("确认合并到数据库？")

    try:
        conn = db_mod.get_connection(ws.db_path, cfg)
    except (OSError, sqlite3.Error) as e:
        ui.error(
            "数据库无法打开",
            detail=str(e),
            next_step="检查工作区目录权限，或用 --workspace 指定可写工作区。",
        )
        raise typer.Exit(1)

    try:
        with ui.progress() as reporter:
            result = pipeline_mod.merge_jsonl(conn, cfg, src_dir, reporter=reporter)
    finally:
        conn.close()

    ui.summary_table(
        "合并完成",
        ["插入", "重复跳过", "错误"],
        [(result.inserted, result.skipped, result.errors)],
    )
    return ui.result(
        "merge",
        "ok",
        input_dir=src_dir,
        database=ws.db_path,
        files=[{"name": f.name, "path": f, "size_bytes": f.stat().st_size} for f in jsonl_files],
        inserted=result.inserted,
        skipped=result.skipped,
        errors=result.errors,
    )

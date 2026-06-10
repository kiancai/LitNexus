from __future__ import annotations

import asyncio
import sqlite3
from typing import Annotated

import typer

from litnexus.cli import context as ctx
from litnexus.cli import ui
from litnexus.cli.options import WorkspaceOption, YesOption
from litnexus.core import db as db_mod
from litnexus.core import translator as trans_mod
from litnexus.core.config import ConfigError, get_api_key, resolved_ai
from litnexus.core.workspace import WorkspaceError

WS_NEXT_STEP = "用 `litnexus init <目录>` 创建工作区，或用 --workspace 指定。"
API_KEY_NEXT_STEP = "设置 LITNEXUS_API_KEY，或在 litnexus.toml 的 [ai].api_key 中填写密钥。"


def translate(
    batch_size: Annotated[int | None, typer.Option(help="覆盖每批翻译数量")] = None,
    concurrency: Annotated[int | None, typer.Option(help="覆盖并发数")] = None,
    dry_run: Annotated[
        bool, typer.Option("--dry-run", help="只显示待翻译数量，不调用 API")
    ] = False,
    workspace: WorkspaceOption = None,
    yes: YesOption = False,
):
    """批量翻译数据库中尚未翻译的文章标题。"""
    try:
        ws, cfg = ctx.load(workspace)
    except (WorkspaceError, ConfigError) as e:
        ui.error("无法加载工作区", detail=str(e), next_step=WS_NEXT_STEP)
        raise typer.Exit(1)
    try:
        get_api_key(cfg)  # 仅校验密钥存在；运行期由 resolved_ai 解析
    except ConfigError as e:
        ui.error("API Key 缺失", detail=str(e), next_step=API_KEY_NEXT_STEP)
        raise typer.Exit(1)

    if batch_size:
        cfg.translate.batch_size = batch_size
    if concurrency:
        cfg.translate.concurrency = concurrency

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
        pending = db_mod.fetch_pending_translations(conn)
        ui.key_values(
            "翻译任务",
            [
                ("待翻译", f"{len(pending)} 篇"),
                ("批量大小", cfg.translate.batch_size),
                ("并发数", cfg.translate.concurrency),
                ("模型", cfg.ai.model),
            ],
        )
        if dry_run or not pending:
            if dry_run:
                ui.info("dry-run：未调用 API，未写入数据库。")
            return ui.result(
                "translate",
                "dry_run" if dry_run else "skipped",
                pending=len(pending),
                batch_size=cfg.translate.batch_size,
                concurrency=cfg.translate.concurrency,
                model=cfg.ai.model,
                translated=0,
                failed=0,
            )
        if not yes:
            ui.confirm("确认开始翻译？")
        with ui.progress() as reporter:
            translated, failed = asyncio.run(
                trans_mod.run_translation(conn, cfg.translate, resolved_ai(cfg), reporter=reporter)
            )
        ui.summary_table("翻译完成", ["成功", "失败"], [(translated, failed)])
        return ui.result(
            "translate",
            "ok",
            pending=len(pending),
            batch_size=cfg.translate.batch_size,
            concurrency=cfg.translate.concurrency,
            model=cfg.ai.model,
            translated=translated,
            failed=failed,
        )
    finally:
        conn.close()

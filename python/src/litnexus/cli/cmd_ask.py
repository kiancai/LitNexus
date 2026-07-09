from __future__ import annotations

import sqlite3
from typing import Annotated

import typer

from litnexus.cli import context as ctx
from litnexus.cli import ui
from litnexus.cli.options import WorkspaceOption, YesOption
from litnexus.core import classifier as cls_mod
from litnexus.core import db as db_mod
from litnexus.core.config import ConfigError, get_api_key, resolved_ai
from litnexus.core.workspace import WorkspaceError

WS_NEXT_STEP = "用 `litnexus init <目录>` 创建工作区，或用 --workspace 指定。"
API_KEY_NEXT_STEP = "设置 LITNEXUS_API_KEY，或在 litnexus.toml 的 [ai].api_key 中填写密钥。"


def ask(
    workers: Annotated[int | None, typer.Option(help="覆盖并发线程数")] = None,
    workspace: WorkspaceOption = None,
    yes: YesOption = False,
):
    """用 AI 对数据库中未分类的文章做多问题分类（直接读写 DB）。"""
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

    if workers:
        cfg.classify.max_workers = workers

    if not cfg.classify.questions:
        ui.error(
            "分类问题为空",
            detail="classify.questions 未定义。",
            next_step="在 litnexus.toml 中添加 [[classify.questions]]。",
        )
        raise typer.Exit(1)

    # 打开已迁移、动态列就绪的连接，整个分类过程复用它
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
        pending = db_mod.fetch_pending_classification(conn, cfg.classify.questions)

        q_ids = ", ".join(q.id for q in cfg.classify.questions)
        ui.key_values(
            "分类任务",
            [
                ("问题列表", q_ids),
                ("待分类", f"{len(pending)} 篇"),
                ("并发线程", cfg.classify.max_workers),
                ("模型", cfg.ai.model),
            ],
        )
        if not pending:
            return ui.result(
                "classify",
                "skipped",
                questions=[q.id for q in cfg.classify.questions],
                pending=0,
                workers=cfg.classify.max_workers,
                model=cfg.ai.model,
                processed=0,
                failed=0,
            )
        if not yes:
            ui.confirm("确认开始分类？")

        with ui.progress() as reporter:
            processed, failed = cls_mod.run_classification(
                conn, cfg.classify, resolved_ai(cfg), reporter=reporter
            )
    finally:
        conn.close()

    ui.summary_table("分类完成", ["处理", "失败"], [(processed, failed)])
    return ui.result(
        "classify",
        "ok",
        questions=[q.id for q in cfg.classify.questions],
        pending=len(pending),
        workers=cfg.classify.max_workers,
        model=cfg.ai.model,
        processed=processed,
        failed=failed,
    )

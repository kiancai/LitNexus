from __future__ import annotations

import sqlite3
from typing import Annotated

import typer

from litnexus.cli import context as ctx
from litnexus.cli import ui
from litnexus.cli.options import WorkspaceOption, YesOption
from litnexus.core import db as db_mod
from litnexus.core.config import ConfigError
from litnexus.core.workspace import WorkspaceError

WS_NEXT_STEP = "用 `litnexus init <目录>` 创建工作区，或用 --workspace 指定。"
DB_NEXT_STEP = "先运行 `litnexus download` 和 `litnexus merge` 创建并导入数据库。"


def _load(workspace):
    """解析工作区，失败时报错并退出。"""
    try:
        return ctx.load(workspace)
    except (WorkspaceError, ConfigError) as e:
        ui.error("无法加载工作区", detail=str(e), next_step=WS_NEXT_STEP)
        raise typer.Exit(1)


def stats(workspace: WorkspaceOption = None):
    """显示数据库统计信息。"""
    ws, cfg = _load(workspace)

    if not ws.db_path.exists():
        ui.error("数据库不存在", detail=str(ws.db_path), next_step=DB_NEXT_STEP)
        raise typer.Exit(1)

    try:
        conn = db_mod.get_connection(ws.db_path, cfg)
    except (OSError, sqlite3.Error) as e:
        ui.error("数据库无法打开", detail=str(e), next_step=DB_NEXT_STEP)
        raise typer.Exit(1)
    try:
        s = db_mod.get_stats(conn, cfg.classify.questions)
        rows = [
            ("总文章数", s["total"]),
            ("待翻译", s["pending_translation"]),
        ]
        for q in cfg.classify.questions:
            key = f"pending_{q.id}"
            if key in s:
                rows.append((f"待分类 {q.id}", s[key]))
                rows.append((f"  {q.id}=是", s.get(f"{q.id}_yes", 0)))
                rows.append((f"  {q.id}=否", s.get(f"{q.id}_no", 0)))
                other = s.get(f"{q.id}_other", 0)
                if other:
                    rows.append((f"  {q.id} 失败/N/A", other))
        if "reviewed_yes" in s:
            rows.append(("include=yes", s["reviewed_yes"]))
        if "reviewed_no" in s:
            rows.append(("include=no", s["reviewed_no"]))
        ui.key_values(
            "数据库",
            [
                ("路径", ws.db_path),
                ("大小", f"{ws.db_path.stat().st_size / 1024 / 1024:.2f} MB"),
            ],
        )
        ui.summary_table("统计", ["指标", "数量"], rows)
        return ui.result(
            "db stats",
            "ok",
            database=ws.db_path,
            size_bytes=ws.db_path.stat().st_size,
            stats=s,
        )
    finally:
        conn.close()


def migrate(workspace: WorkspaceOption = None):
    """手动触发数据库 schema 迁移 / 动态列同步，并报告实际状态。"""
    ws, cfg = _load(workspace)
    existed = ws.db_path.exists()
    try:
        # get_connection 会自动迁移到最新版本并补齐动态列
        conn = db_mod.get_connection(ws.db_path, cfg)
    except (OSError, sqlite3.Error) as e:
        ui.error("数据库无法打开", detail=str(e), next_step="检查工作区目录权限。")
        raise typer.Exit(1)
    try:
        version = db_mod.get_schema_version(conn)
        columns = db_mod.list_columns(conn)
        if not existed:
            ui.success(f"已创建新数据库（schema v{version}）。")
        else:
            ui.success(f"schema 已是最新（v{version}），动态列已确认存在。")
        ui.key_values(
            "数据库",
            [
                ("路径", ws.db_path),
                ("schema 版本", f"v{version}（最新 v{db_mod.SCHEMA_VERSION}）"),
                ("列数", len(columns)),
            ],
        )
        return ui.result(
            "db migrate",
            "ok",
            database=ws.db_path,
            version=version,
            schema_version=db_mod.SCHEMA_VERSION,
            columns=columns,
        )
    finally:
        conn.close()


def reset_classification(
    failed_only: Annotated[
        bool,
        typer.Option(
            "--failed/--all",
            help="--failed（默认）：仅重置旧的 API错误 失败行；--all：重置全部分类结果重跑",
        ),
    ] = True,
    workspace: WorkspaceOption = None,
    yes: YesOption = False,
):
    """把分类结果（{id}_ans/{id}_rea）置回 NULL，以便下次 `classify` 重新分类。"""
    ws, cfg = _load(workspace)

    if not ws.db_path.exists():
        ui.error("数据库不存在", detail=str(ws.db_path), next_step=DB_NEXT_STEP)
        raise typer.Exit(1)
    if not cfg.classify.questions:
        ui.error(
            "分类问题为空",
            detail="classify.questions 未定义。",
            next_step="在 litnexus.toml 中添加 [[classify.questions]]。",
        )
        raise typer.Exit(1)

    scope = "仅旧失败行（API错误）" if failed_only else "全部已分类结果"
    q_ids = ", ".join(q.id for q in cfg.classify.questions)
    ui.key_values("重置分类", [("范围", scope), ("问题", q_ids)])
    if not yes:
        ui.confirm("确认把这些分类结果清空以便重跑？")

    try:
        conn = db_mod.get_connection(ws.db_path, cfg)
    except (OSError, sqlite3.Error) as e:
        ui.error("数据库无法打开", detail=str(e), next_step=DB_NEXT_STEP)
        raise typer.Exit(1)
    try:
        counts = db_mod.reset_classification(
            conn, cfg.classify.questions, only_failed=failed_only
        )
    finally:
        conn.close()

    total = sum(counts.values())
    ui.summary_table("重置完成", ["问题", "清空行数"], list(counts.items()))
    ui.success(f"已清空 {total} 处分类结果，下次 `litnexus classify` 将重新处理。")
    return ui.result(
        "db reset-classification", "ok", database=ws.db_path, reset=counts, total=total
    )


def backup(workspace: WorkspaceOption = None):
    """备份数据库文件。"""
    ws, _cfg = _load(workspace)

    if not ws.db_path.exists():
        ui.error("数据库不存在", detail=str(ws.db_path), next_step=DB_NEXT_STEP)
        raise typer.Exit(1)

    bak = db_mod.backup(ws.db_path)
    ui.success("数据库备份完成。")
    ui.key_values("备份文件", [("路径", bak)])
    return ui.result("db backup", "ok", database=ws.db_path, backup=bak)

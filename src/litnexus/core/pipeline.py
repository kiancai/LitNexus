"""流水线步骤的纯逻辑实现，供 CLI 与 GUI 共用。

这里只做「干活」，不含任何终端/网页 UI；进度通过可选的 reporter 适配器上报
（reporter 需提供 add_task/update/complete/log，详见 cli/ui.ProgressReporter）。
把这些逻辑集中在一处，避免 CLI 的 cmd_* 与 GUI 的 _do_* 各写一份、随时间发散。
"""

from __future__ import annotations

import logging
import sqlite3
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Any

from litnexus.core import db as db_mod
from litnexus.core import fields as fields_mod
from litnexus.core import io as io_mod

if TYPE_CHECKING:
    from litnexus.core.config import Config

logger = logging.getLogger(__name__)


def _emit(reporter: Any | None, message: str) -> None:
    """逐条进度消息：有 reporter（CLI）走其日志，否则（GUI/无 UI）走 logging。"""
    if reporter is not None:
        reporter.log(message)
    else:
        logger.info(message)


@dataclass
class MergeResult:
    inserted: int
    skipped: int
    errors: int
    files: int


def merge_jsonl(
    conn: sqlite3.Connection,
    cfg: Config,
    src_dir: Path,
    *,
    reporter: Any | None = None,
) -> MergeResult:
    """把 src_dir 下所有 *.jsonl 解析、入库（INSERT OR IGNORE 去重），返回统计。

    缺 epmc_id 的记录计入 errors 并跳过。不打印任何 UI，仅经 reporter 上报进度。
    """
    extra = fields_mod.active_extra_fields(cfg.ingest.extra_fields)
    files = sorted(src_dir.glob("*.jsonl"))
    inserted = skipped = errors = 0
    task_id = reporter.add_task("合并 JSONL", total=len(files)) if reporter is not None else None

    for fpath in files:
        _emit(reporter, f"处理：{fpath.name}")
        batch = []
        file_errors = 0
        for raw in io_mod.iter_jsonl(fpath):
            parsed = io_mod.parse_article(raw, extra)
            if parsed.get("epmc_id"):
                batch.append(parsed)
            else:
                file_errors += 1
        i, s = db_mod.insert_articles(conn, batch)
        inserted += i
        skipped += s
        errors += file_errors
        _emit(reporter, f"  {fpath.name}: 插入 {i}，跳过 {s}，错误 {file_errors}")
        if reporter is not None:
            reporter.update(task_id, advance=1)

    if reporter is not None:
        reporter.complete(task_id)
    return MergeResult(inserted, skipped, errors, len(files))


def export_articles(
    conn: sqlite3.Connection,
    cfg: Config,
    filter_mode: str,
    output: Path,
) -> int:
    """按 filter_mode 查询并导出到 output（CSV），返回导出行数（0 表示结果为空）。

    filter_mode 非法（如 pending 模式缺 include 列）时由 db.fetch_for_export 抛 ValueError。
    """
    df = db_mod.fetch_for_export(conn, filter_mode)
    if df.empty:
        return 0
    return io_mod.export_to_csv(df, output, cfg.export.exclude_columns)

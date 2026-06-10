"""CLI 输出辅助（基于 Rich）。

只面向人类阅读：彩色表格 + 进度条；`--plain` / `--no-color` 用于日志与管道。
（不再提供 --json 输出——结构化数据请直接读工作区里的 SQLite。）
"""

from __future__ import annotations

import re
from collections.abc import Iterable, Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import typer
from rich import box
from rich.console import Console
from rich.markup import escape
from rich.progress import (
    BarColumn,
    Progress,
    SpinnerColumn,
    TaskID,
    TextColumn,
    TimeElapsedColumn,
)
from rich.table import Table

_BACKTICK_RE = re.compile(r"`([^`]+)`")


@dataclass
class UISettings:
    plain: bool = False
    color: bool = True


_settings = UISettings()
_console = Console()
_err_console = Console(stderr=True)


def configure_ui(*, plain: bool = False, no_color: bool = False) -> None:
    """配置全局渲染选项。"""
    global _console, _err_console
    _settings.plain = plain
    _settings.color = not no_color
    no_color_final = no_color or plain
    markup = not plain
    _console = Console(
        no_color=no_color_final, highlight=False, markup=markup, soft_wrap=True
    )
    _err_console = Console(
        stderr=True, no_color=no_color_final, highlight=False, markup=markup, soft_wrap=True
    )


def console() -> Console:
    return _console


def _plain_print(message: str, *, err: bool = False) -> None:
    typer.echo(message, err=err)


def _markup(message: Any) -> str:
    """把 `反引号` 渲染成青色，其余转义，避免 Rich 误解析方括号。"""
    text = "" if message is None else str(message)
    parts: list[str] = []
    cursor = 0
    for match in _BACKTICK_RE.finditer(text):
        parts.append(escape(text[cursor : match.start()]))
        parts.append(f"[cyan]{escape(match.group(1))}[/cyan]")
        cursor = match.end()
    parts.append(escape(text[cursor:]))
    return "".join(parts)


def result(command: str, status: str = "ok", **fields: Any) -> dict[str, Any]:
    """构造并返回一个结果字典（供 `run` 汇总各步骤）。"""
    return {"command": command, "status": status, **fields}


def title(text: str, subtitle: str | None = None) -> None:
    if _settings.plain:
        _plain_print(f"\n{text}")
        if subtitle:
            _plain_print(subtitle)
        _plain_print("")
        return
    _console.print()
    _console.print(f"[cyan]→[/cyan] {_markup(text)}")
    if subtitle:
        _console.print(_markup(subtitle))
    _console.print()


def info(message: str) -> None:
    if _settings.plain:
        _plain_print(f"→ {message}")
    else:
        _console.print(f"[cyan]→[/cyan] {_markup(message)}")


def success(message: str) -> None:
    if _settings.plain:
        _plain_print(f"✓ {message}")
    else:
        _console.print(f"[green]✓[/green] {_markup(message)}")


def warning(message: str) -> None:
    if _settings.plain:
        _plain_print(f"! {message}")
    else:
        _console.print(f"[yellow]![/yellow] {_markup(message)}")


def error(message: str, *, detail: str | None = None, next_step: str | None = None) -> None:
    if _settings.plain:
        _plain_print(f"✗ {message}", err=True)
        if next_step:
            _plain_print(next_step, err=True)
        elif detail:
            _plain_print(detail, err=True)
        return
    _err_console.print(f"[red]✗[/red] {_markup(message)}")
    if next_step:
        _err_console.print(_markup(next_step))
    elif detail:
        _err_console.print(_markup(detail))


def confirm(prompt: str) -> None:
    typer.confirm(prompt, abort=True)


def _is_number(value: Any) -> bool:
    if isinstance(value, bool):
        return False
    if isinstance(value, int | float):
        return True
    text = str(value).replace(",", "")
    return text.isdigit()


def key_values(title_text: str, rows: Iterable[tuple[str, Any]]) -> None:
    summary_table(title_text, ["key", "value"], rows)


def summary_table(title_text: str, columns: list[str], rows: Iterable[Iterable[Any]]) -> None:
    rows_list = [[str(cell) for cell in row] for row in rows]
    if _settings.plain:
        _plain_print(f"\n{title_text}")
        _plain_print("  " + " | ".join(columns))
        for row in rows_list:
            _plain_print("  " + " | ".join(row))
        _plain_print("")
        return

    _console.print()
    _console.print(_markup(title_text))
    table = Table(
        box=box.SIMPLE,
        show_header=True,
        show_lines=False,
        header_style="bold",
        padding=(0, 1),
    )
    for idx, col in enumerate(columns):
        lower = col.lower()
        values = [row[idx] for row in rows_list if idx < len(row)]
        justify = "left"
        if "状态" in col or "status" in lower:
            justify = "center"
        elif values and all(_is_number(value) for value in values):
            justify = "right"
        table.add_column(col, justify=justify)
    for row in rows_list:
        table.add_row(*row)
    _console.print(table)
    _console.print()


def path_text(path: Path) -> str:
    return str(path.expanduser())


class ProgressReporter:
    """供 core 代码使用的进度适配器，不依赖 Rich 直接耦合。"""

    def __init__(self, progress: Progress | None) -> None:
        self._progress = progress

    def add_task(self, description: str, total: int | None = None) -> TaskID | None:
        if self._progress is None:
            return None
        return self._progress.add_task(description, total=total)

    def update(
        self,
        task_id: TaskID | None,
        *,
        advance: int = 0,
        completed: int | None = None,
        total: int | None = None,
        description: str | None = None,
    ) -> None:
        if self._progress is None or task_id is None:
            return
        kwargs: dict[str, Any] = {}
        if completed is not None:
            kwargs["completed"] = completed
        if total is not None:
            kwargs["total"] = total
        if description is not None:
            kwargs["description"] = description
        self._progress.update(task_id, advance=advance, **kwargs)

    def complete(self, task_id: TaskID | None) -> None:
        if self._progress is None or task_id is None:
            return
        task = self._progress.tasks[task_id]
        if task.total is not None:
            self._progress.update(task_id, completed=task.total)

    def log(self, message: str) -> None:
        if self._progress is None:
            return
        self._progress.console.print(_markup(message))


@contextmanager
def progress(*, bar: bool = True) -> Iterator[ProgressReporter]:
    if _settings.plain:
        yield ProgressReporter(None)
        return

    columns: list[Any] = [
        SpinnerColumn(style="cyan"),
        TextColumn("{task.description}"),
    ]
    if bar:
        columns.extend(
            [
                BarColumn(
                    bar_width=None,
                    complete_style="cyan",
                    finished_style="cyan",
                    pulse_style="cyan",
                ),
                TextColumn("{task.completed}/{task.total}"),
            ]
        )
    columns.append(TimeElapsedColumn())

    progress_view = Progress(*columns, console=_console, transient=False)
    with progress_view:
        yield ProgressReporter(progress_view)

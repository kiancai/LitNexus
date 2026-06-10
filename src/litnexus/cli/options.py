"""Shared Typer option types and CLI enums."""

from __future__ import annotations

from enum import StrEnum
from pathlib import Path
from typing import Annotated

import typer


class DownloadMode(StrEnum):
    journals = "journals"
    keywords = "keywords"
    all = "all"


WorkspaceOption = Annotated[
    Path | None,
    typer.Option("--workspace", "-w", help="工作区目录（默认使用当前活动工作区）"),
]
YesOption = Annotated[
    bool,
    typer.Option("--yes", "-y", help="跳过确认"),
]
DownloadModeOption = Annotated[
    DownloadMode,
    typer.Option(
        "--mode",
        "-m",
        case_sensitive=False,
        help="下载来源模式",
    ),
]

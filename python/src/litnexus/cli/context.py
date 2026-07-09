"""CLI 公共逻辑：解析工作区并加载其配置。"""

from __future__ import annotations

from pathlib import Path

from litnexus.core.config import Config, ConfigError, load_config
from litnexus.core.workspace import Workspace, WorkspaceError, resolve_workspace

__all__ = ["Config", "ConfigError", "Workspace", "WorkspaceError", "load"]


def load(workspace: Path | None) -> tuple[Workspace, Config]:
    """解析工作区并加载其 litnexus.toml。

    解析失败（找不到工作区或配置文件）时抛 WorkspaceError / ConfigError，
    由调用方统一转成用户可读的报错。
    """
    ws = resolve_workspace(workspace)
    cfg = load_config(ws.config_path)
    return ws, cfg

from __future__ import annotations

import pytest

from litnexus.core import workspace as ws_mod
from litnexus.core.config import load_config
from litnexus.core.workspace import create_workspace


@pytest.fixture
def isolated_state(tmp_path, monkeypatch):
    """把工作区指针文件隔离到临时目录，避免污染真实 state.toml；并清掉相关环境变量。"""
    state_dir = tmp_path / "_state"
    monkeypatch.setattr(ws_mod, "_STATE_DIR", state_dir)
    monkeypatch.setattr(ws_mod, "_STATE_FILE", state_dir / "state.toml")
    for var in (
        "LITNEXUS_WORKSPACE",
        "LITNEXUS_API_KEY",
        "ARK_API_KEY",
        "LITNEXUS_BASE_URL",
        "ARK_API_BASE_URL",
    ):
        monkeypatch.delenv(var, raising=False)
    return tmp_path


@pytest.fixture
def ws_cfg(isolated_state):
    """一个全新初始化的工作区及其默认配置。"""
    ws = create_workspace(isolated_state / "ws")
    return ws, load_config(ws.config_path)

from __future__ import annotations

import pytest

from litnexus.core.workspace import (
    WorkspaceError,
    create_workspace,
    get_active,
    resolve_workspace,
)


def test_create_workspace_lays_out_files(isolated_state):
    root = isolated_state / "ws"
    ws = create_workspace(root)
    assert ws.config_path.exists()
    assert ws.journals_file.exists()
    assert (root / "keywords.txt").exists()
    assert ws.downloads_dir.is_dir()
    assert ws.exports_dir.is_dir()
    assert ws.is_initialized()
    assert get_active() == root.resolve()


def test_resolve_precedence(isolated_state, monkeypatch):
    a = create_workspace(isolated_state / "A")
    b = create_workspace(isolated_state / "B")  # 最后创建的成为活动工作区
    assert resolve_workspace(None).root == b.root  # 活动指针
    assert resolve_workspace(a.root).root == a.root  # 显式参数优先
    monkeypatch.setenv("LITNEXUS_WORKSPACE", str(a.root))
    assert resolve_workspace(None).root == a.root  # 环境变量优先于活动指针


def test_resolve_uninitialized_raises(isolated_state):
    with pytest.raises(WorkspaceError):
        resolve_workspace(isolated_state / "missing")


def test_resolve_without_active_raises(isolated_state):
    with pytest.raises(WorkspaceError):
        resolve_workspace(None)

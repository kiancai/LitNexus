"""run 一键流水线编排测试（P1：步骤级容错 + 预检前置）。"""

from __future__ import annotations

import pytest
import typer

from litnexus.cli import app as app_mod
from litnexus.cli import cmd_download, cmd_merge
from litnexus.cli.options import DownloadMode


def test_run_aborts_gracefully_on_step_error(ws_cfg, monkeypatch):
    """某步抛运行时异常时，run 应被隔离为 Exit(1)，而非原始 traceback。"""
    ws, _cfg = ws_cfg

    def ok_download(**k):
        return {"command": "download", "status": "ok"}

    monkeypatch.setattr(cmd_download, "download", ok_download)

    def boom(**k):
        raise RuntimeError("merge boom")

    monkeypatch.setattr(cmd_merge, "merge", boom)

    with pytest.raises(typer.Exit) as ei:
        app_mod.run(
            from_step=1, to_step=2, skip_steps=None,
            mode=DownloadMode.all, days=None, workspace=ws.root, yes=True,
        )
    assert ei.value.exit_code == 1


def test_run_precheck_missing_api_key_fails_fast(ws_cfg, monkeypatch):
    """步骤 3/4 缺 API Key 时，预检应在跑任何步骤前就退出。"""
    ws, _cfg = ws_cfg

    def fail(**k):
        raise AssertionError("预检失败时不应执行任何流水线步骤")

    monkeypatch.setattr(cmd_download, "download", fail)
    monkeypatch.setattr(cmd_merge, "merge", fail)

    with pytest.raises(typer.Exit) as ei:
        app_mod.run(
            from_step=3, to_step=3, skip_steps=None,
            mode=DownloadMode.all, days=None, workspace=ws.root, yes=True,
        )
    assert ei.value.exit_code == 1

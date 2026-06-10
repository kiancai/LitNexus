"""工作区：一个自包含目录，存放 LitNexus 的全部用户数据。

工作区类似 Obsidian 的 vault —— 所有数据都集中在一个文件夹里，便于备份、
同步（同步盘 / git）和跨平台迁移：

    <root>/
    ├── litnexus.toml   配置（GUI 表单读写，也可手动编辑）
    ├── journals.txt    期刊列表
    ├── keywords.txt    关键词检索式列表（也支持 keywords/*.txt 多文件）
    ├── litnexus.db     SQLite 数据库
    ├── downloads/      下载的原始 JSONL
    └── exports/        导出的 CSV

唯一存在工作区之外的，是一个记录「当前/最近工作区在哪」的指针文件，放在
操作系统标准配置目录（由 platformdirs 跨平台决定：Windows %APPDATA%、
macOS ~/Library/Application Support、Linux ~/.config）。
"""

from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass
from pathlib import Path

import platformdirs
import tomli_w

APP_NAME = "litnexus"

CONFIG_FILENAME = "litnexus.toml"
DB_FILENAME = "litnexus.db"
JOURNALS_FILENAME = "journals.txt"
KEYWORDS_FILENAME = "keywords.txt"

WORKSPACE_ENV = "LITNEXUS_WORKSPACE"

# 指针文件：记录 active（当前工作区）与 recent（最近打开列表），是唯一在工作区外的状态。
_STATE_DIR = Path(platformdirs.user_config_dir(APP_NAME))
_STATE_FILE = _STATE_DIR / "state.toml"
_MAX_RECENT = 10


class WorkspaceError(Exception):
    """工作区无法解析或未初始化。"""


@dataclass(frozen=True)
class Workspace:
    """一个工作区根目录及其下的标准路径。"""

    root: Path

    @property
    def config_path(self) -> Path:
        return self.root / CONFIG_FILENAME

    @property
    def db_path(self) -> Path:
        return self.root / DB_FILENAME

    @property
    def downloads_dir(self) -> Path:
        return self.root / "downloads"

    @property
    def exports_dir(self) -> Path:
        return self.root / "exports"

    @property
    def journals_file(self) -> Path:
        return self.root / JOURNALS_FILENAME

    @property
    def keywords_files(self) -> list[Path]:
        """关键词文件列表：根目录下的 keywords.txt，外加可选 keywords/ 目录下所有 .txt。"""
        single = self.root / KEYWORDS_FILENAME
        files = [single] if single.exists() else []
        kw_dir = self.root / "keywords"
        if kw_dir.is_dir():
            files.extend(sorted(kw_dir.glob("*.txt")))
        return files or [single]

    def is_initialized(self) -> bool:
        """是否为一个已初始化的工作区（存在配置文件）。"""
        return self.config_path.exists()

    def ensure_dirs(self) -> None:
        """确保下载/导出子目录存在。"""
        self.downloads_dir.mkdir(parents=True, exist_ok=True)
        self.exports_dir.mkdir(parents=True, exist_ok=True)


# ── 指针文件（active / recent）─────────────────────────────────────────────────


def _read_state() -> dict:
    if not _STATE_FILE.exists():
        return {}
    try:
        with open(_STATE_FILE, "rb") as f:
            return tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError):
        return {}


def _write_state(state: dict) -> None:
    _STATE_DIR.mkdir(parents=True, exist_ok=True)
    with open(_STATE_FILE, "wb") as f:
        tomli_w.dump(state, f)


def get_active() -> Path | None:
    """返回当前活动工作区路径（若有）。"""
    root = _read_state().get("active")
    return Path(root) if root else None


def list_recent() -> list[Path]:
    """返回最近打开过的工作区路径列表（最新在前）。"""
    return [Path(p) for p in _read_state().get("recent", [])]


def set_active(root: Path) -> None:
    """把某工作区设为活动，并更新 recent 列表。"""
    resolved = str(root.expanduser().resolve())
    state = _read_state()
    state["active"] = resolved
    recent = [resolved] + [p for p in state.get("recent", []) if p != resolved]
    state["recent"] = recent[:_MAX_RECENT]
    _write_state(state)


# ── 解析 / 创建 ────────────────────────────────────────────────────────────────


def resolve_workspace(explicit: Path | None = None) -> Workspace:
    """按优先级解析工作区：显式参数 > 环境变量 > 活动指针。

    解析不到、或目录未初始化时抛 WorkspaceError（含引导用户的下一步）。
    """
    if explicit is not None:
        candidate: Path | None = explicit
    elif os.environ.get(WORKSPACE_ENV):
        candidate = Path(os.environ[WORKSPACE_ENV])
    else:
        candidate = get_active()

    if candidate is None:
        raise WorkspaceError(
            "未找到工作区。请先用 `litnexus init <目录>` 创建一个工作区，"
            f"或用 --workspace 指定，或设置 {WORKSPACE_ENV} 环境变量。"
        )

    ws = Workspace(candidate.expanduser().resolve())
    if not ws.is_initialized():
        raise WorkspaceError(
            f"工作区未初始化：{ws.root}（缺少 {CONFIG_FILENAME}）。"
            f"用 `litnexus init {ws.root}` 创建。"
        )
    return ws


def create_workspace(root: Path, *, force: bool = False) -> Workspace:
    """在 root 创建工作区：建目录、写模板文件、并设为活动工作区。

    已存在的文件默认保留（force=True 时覆盖）。
    """
    # 延迟导入避免与 config 形成循环依赖。
    from litnexus.core.config import (
        DEFAULT_CONFIG_TOML,
        DEFAULT_JOURNALS_TXT,
        DEFAULT_KEYWORDS_TXT,
    )

    ws = Workspace(root.expanduser().resolve())
    ws.root.mkdir(parents=True, exist_ok=True)
    ws.ensure_dirs()

    templates = {
        ws.config_path: DEFAULT_CONFIG_TOML,
        ws.journals_file: DEFAULT_JOURNALS_TXT,
        ws.root / KEYWORDS_FILENAME: DEFAULT_KEYWORDS_TXT,
    }
    for path, content in templates.items():
        if force or not path.exists():
            path.write_text(content, encoding="utf-8")

    set_active(ws.root)
    return ws

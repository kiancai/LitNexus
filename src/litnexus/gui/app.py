"""LitNexus 配置面板（NiceGUI，v2）。

单页布局，从上到下：数据 → 运行 → 配置。深色 Dracula 为默认主题，可切换浅色。
字段说明用「?」悬停提示，文案来自可编辑的 help.toml；复筛仍在 Excel 完成。
"""

from __future__ import annotations

import asyncio
import datetime
import logging
import os
import subprocess
import sys
import tomllib
from pathlib import Path

import platformdirs
from nicegui import app as nicegui_app
from nicegui import run as ng_run
from nicegui import ui

from litnexus.core import db as db_mod
from litnexus.core import epmc as epmc_mod
from litnexus.core import fields as fields_mod
from litnexus.core import io as io_mod
from litnexus.core import pipeline as pipeline_mod
from litnexus.core import translator as trans_mod
from litnexus.core import workspace as ws_mod
from litnexus.core.classifier import run_classification
from litnexus.core.config import Config, Question, load_config, resolved_ai
from litnexus.core.config_saver import save_config
from litnexus.core.workspace import Workspace, WorkspaceError

logger = logging.getLogger(__name__)

# ── Dracula 调色板 + 主题 CSS ─────────────────────────────────────────────────

DRACULA = {
    "bg": "#282a36",
    "panel": "#343746",
    "line": "#44475a",
    "fg": "#f8f8f2",
    "comment": "#6272a4",
    "purple": "#bd93f9",
    "pink": "#ff79c6",
    "cyan": "#8be9fd",
    "green": "#50fa7b",
    "yellow": "#f1fa8c",
    "red": "#ff5555",
}

APP_CSS = f"""
:root {{ --lit-radius: 16px; }}
body, .q-page, .nicegui-content {{
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC",
                 "Microsoft YaHei", Roboto, system-ui, sans-serif;
    -webkit-font-smoothing: antialiased;
}}
.nicegui-content {{ padding: 0; }}
.lit-main {{ width: 100%; max-width: 980px; margin: 0 auto; padding: 24px 20px 96px; gap: 20px; }}
.lit-header {{ backdrop-filter: saturate(180%) blur(12px); border-bottom: 1px solid rgba(128,128,128,.18); }}
.lit-nav {{ text-decoration: none; opacity: .8; font-weight: 600; }}
.lit-nav:hover {{ opacity: 1; }}
.lit-card {{
    border-radius: var(--lit-radius);
    box-shadow: 0 1px 2px rgba(0,0,0,.06), 0 12px 32px rgba(0,0,0,.05);
    padding: 22px 24px;
}}
.lit-section-title {{ font-size: 1.3rem; font-weight: 700; letter-spacing: -.01em; }}
.lit-stat {{ border-radius: var(--lit-radius); min-width: 130px; padding: 16px 18px; }}
.lit-log {{ border-radius: 12px; font-family: "SF Mono", ui-monospace, Menlo, monospace; font-size: 12px; }}

/* 浅色：Apple 风的中性灰白 */
.body--light {{ background: #f5f5f7; color: #1d1d1f; }}
.body--light .lit-header {{ background: rgba(255,255,255,.72); color: #1d1d1f; }}
.body--light .lit-card, .body--light .lit-stat {{ background: #ffffff; }}
.body--light .lit-log {{ background: #1d1d1f; color: #e6e6e6; }}

/* 深色：Dracula */
.body--dark {{ background: {DRACULA["bg"]}; color: {DRACULA["fg"]}; }}
.body--dark .lit-header {{ background: rgba(40,42,54,.72); color: {DRACULA["fg"]}; }}
.body--dark .lit-card, .body--dark .lit-stat {{
    background: {DRACULA["panel"]}; border: 1px solid {DRACULA["line"]};
}}
.body--dark .lit-log {{ background: #1a1b23; color: {DRACULA["green"]}; }}
.body--dark .lit-section-title {{ color: {DRACULA["fg"]}; }}
"""

# ── 字段提示（可编辑的 help.toml）─────────────────────────────────────────────

_HELP_FILE = Path(platformdirs.user_config_dir(ws_mod.APP_NAME)) / "help.toml"

DEFAULT_HELP_TOML = """\
# LitNexus 字段提示文案（GUI 里 ? 悬停显示）。可自由编辑，保存后刷新页面生效。
[help]
journals = "每行一个期刊名，需与 Europe PMC 中的名称完全一致；# 开头为注释。例：Nature"
keywords = "每行一个检索式，支持 Europe PMC 布尔语法。例：(microbiome OR microbiota) AND \\"machine learning\\""
base_url = "AI 服务的 OpenAI 兼容接口地址。豆包/方舟示例：https://ark.cn-beijing.volces.com/api/v3"
model = "要调用的模型名称，需与服务商提供的完全一致。"
api_key = "API 密钥。留空则读取环境变量 LITNEXUS_API_KEY 或 ARK_API_KEY，避免写入文件。"
questions = "AI 初筛问题：每条一个，AI 对每篇文章回答是/否；id 会成为数据库列名（{id}_ans / {id}_rea）。"
annotation_columns = "复筛时人工填写的列（导出到 CSV 里手动标记）。include 用于筛选与统计（yes/no），可再加 tags、priority、notes 等。"
extra_fields = "除标题/摘要等核心字段外，额外从 Europe PMC 抓取入库的字段，勾选后下次合并生效。"
exclude_columns = "导出 CSV 时排除的列（通常排除大段 JSON / 不需要人工看的列）。"
export_filter = "导出范围：pending=未复筛(include 为空)，all=全部，或自定义 SQL WHERE 子句。"
days = "下载最近多少天内首次发表的文章。"
page_size = "每次 API 请求返回的数量，建议保持 1000。"
request_delay = "每页请求之间的间隔秒数，避免被限速。"
batch_size = "每次 API 调用翻译多少个标题。"
concurrency = "翻译的并发请求数。"
max_workers = "AI 分类的并发线程数。"
"""


def _load_help() -> dict:
    if not _HELP_FILE.exists():
        try:
            _HELP_FILE.parent.mkdir(parents=True, exist_ok=True)
            _HELP_FILE.write_text(DEFAULT_HELP_TOML, encoding="utf-8")
        except OSError:
            pass
    try:
        with open(_HELP_FILE, "rb") as f:
            return tomllib.load(f).get("help", {})
    except (OSError, tomllib.TOMLDecodeError):
        return {}


# ── 共享状态 ──────────────────────────────────────────────────────────────────


class _State:
    def __init__(self) -> None:
        self.ws: Workspace | None = None
        self.cfg: Config | None = None
        self.help: dict = {}

    def open(self, root: Path) -> None:
        self.ws = ws_mod.create_workspace(root)
        self.cfg = load_config(self.ws.config_path)

    def reload(self) -> None:
        if self.ws is not None:
            self.cfg = load_config(self.ws.config_path)


# 模块级单例：本应用按「单用户、单实例」使用（litnexus gui / --native）。
# 多个浏览器标签会共享同一 STATE/工作区，切换工作区会影响所有标签——这是有意的简化。
STATE = _State()


# ── 小工具 ────────────────────────────────────────────────────────────────────


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return ""


def _has_terms(path: Path) -> bool:
    return any(
        line.strip() and not line.strip().startswith("#") for line in _read_text(path).splitlines()
    )


def _open_in_file_manager(path: Path) -> None:
    try:
        if sys.platform == "darwin":
            subprocess.run(["open", str(path)], check=False)
        elif sys.platform == "win32":
            os.startfile(str(path))  # type: ignore[attr-defined]
        else:
            subprocess.run(["xdg-open", str(path)], check=False)
    except OSError as e:
        ui.notify(f"打不开目录：{e}", type="negative")


def _field_label(text: str, help_key: str, help_map: dict) -> None:
    with ui.row().classes("items-center gap-1 no-wrap q-mb-xs"):
        ui.label(text).classes("text-sm text-weight-medium")
        tip = help_map.get(help_key)
        if tip:
            ui.icon("help_outline").classes("cursor-help").style(
                "font-size:16px;opacity:.55"
            ).tooltip(tip)


def _section_title(text: str) -> None:
    ui.label(text).classes("lit-section-title q-mb-md")


def _logo(ws: Workspace) -> None:
    for cand in (ws.root / "logo.png", ws.root / "logo.svg", _HELP_FILE.parent / "logo.png"):
        if cand.exists():
            ui.image(str(cand)).classes("w-8 h-8").style("object-fit:contain")
            return
    ui.icon("biotech").classes("text-2xl").style(f"color:{DRACULA['purple']}")


# ── 流水线步骤（后台线程执行）────────────────────────────────────────────────


class _UILogHandler(logging.Handler):
    def __init__(self, log: ui.log) -> None:
        super().__init__()
        self.log = log

    def emit(self, record: logging.LogRecord) -> None:
        try:
            self.log.push(self.format(record))
        except Exception:
            pass


class _LogReporter:
    """把核心模块的进度上报转成节流的 logging，让 GUI 日志面板能看到百分比进度。

    实现 core 期望的 reporter 协议（add_task/update/complete/log）；这些 logging
    经 _UILogHandler 推送到页面 ui.log。
    """

    def __init__(self) -> None:
        self._tasks: dict[int, dict] = {}
        self._next = 0

    def add_task(self, description: str, total: int | None = None) -> int:
        tid = self._next
        self._next += 1
        self._tasks[tid] = {"desc": description, "total": total, "done": 0, "last_pct": -1}
        logger.info(f"{description}：开始" + (f"（共 {total}）" if total else ""))
        return tid

    def update(self, task_id, *, advance=0, completed=None, total=None, description=None) -> None:
        t = self._tasks.get(task_id)
        if t is None:
            return
        if total is not None:
            t["total"] = total
        t["done"] = completed if completed is not None else t["done"] + advance
        tot = t["total"]
        if tot:
            pct = int(t["done"] * 100 / tot)
            if pct >= t["last_pct"] + 10:  # 每约 10% 记一次，避免刷屏
                t["last_pct"] = pct
                logger.info(f"{t['desc']}：{t['done']}/{tot}（{pct}%）")

    def complete(self, task_id) -> None:
        t = self._tasks.get(task_id)
        if t is not None:
            logger.info(f"{t['desc']}：完成")

    def log(self, message: str) -> None:
        logger.info(message)


async def _run_blocking(name: str, fn, log: ui.log, on_done=None) -> None:
    handler = _UILogHandler(log)
    handler.setFormatter(logging.Formatter("%(message)s"))
    root_logger = logging.getLogger("litnexus")
    prev_level = root_logger.level
    root_logger.addHandler(handler)
    root_logger.setLevel(logging.INFO)
    log.push(f"▶ 开始：{name}")
    try:
        result = await ng_run.io_bound(fn)
        log.push(f"✓ 完成：{name}  {result if result is not None else ''}")
        ui.notify(f"{name} 完成", type="positive")
    except Exception as e:  # noqa: BLE001
        log.push(f"✗ 失败：{name}：{e}")
        ui.notify(f"{name} 失败：{e}", type="negative")
    finally:
        root_logger.removeHandler(handler)
        root_logger.setLevel(prev_level)
    if on_done:
        on_done()


def _do_download(cfg: Config, ws: Workspace, mode: str, days: int) -> str:
    files = epmc_mod.run_download(cfg, ws, mode=mode, days=days, reporter=_LogReporter())
    return f"生成 {len(files)} 个 JSONL 文件"


def _do_merge(cfg: Config, ws: Workspace) -> str:
    conn = db_mod.get_connection(ws.db_path, cfg)
    try:
        r = pipeline_mod.merge_jsonl(conn, cfg, ws.downloads_dir, reporter=_LogReporter())
    finally:
        conn.close()
    return f"插入 {r.inserted}，重复 {r.skipped}，错误 {r.errors}"


def _do_translate(cfg: Config, ws: Workspace) -> str:
    ai = resolved_ai(cfg)  # 解析 env，不写回共享的 STATE.cfg（避免密钥落盘）
    conn = db_mod.get_connection(ws.db_path, cfg)
    try:
        translated, failed = asyncio.run(
            trans_mod.run_translation(conn, cfg.translate, ai, reporter=_LogReporter())
        )
    finally:
        conn.close()
    return f"翻译 {translated}，失败 {failed}"


def _do_classify(cfg: Config, ws: Workspace) -> str:
    ai = resolved_ai(cfg)  # 解析 env，不写回共享的 STATE.cfg（避免密钥落盘）
    conn = db_mod.get_connection(ws.db_path, cfg)
    try:
        processed, failed = run_classification(conn, cfg.classify, ai, reporter=_LogReporter())
    finally:
        conn.close()
    return f"分类 {processed}，失败 {failed}"


def _do_export(cfg: Config, ws: Workspace, filter_mode: str) -> str:
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    out = ws.exports_dir / f"articles_{ts}.csv"
    conn = db_mod.get_connection(ws.db_path, cfg)
    try:
        n = pipeline_mod.export_articles(cfg=cfg, conn=conn, filter_mode=filter_mode, output=out)
    except ValueError as e:
        return f"无法导出：{e}"
    finally:
        conn.close()
    return "查询结果为空，未生成 CSV" if n == 0 else f"已导出 {n} 篇 → {out}"


def _readiness(ws: Workspace, cfg: Config) -> dict:
    has_terms = _has_terms(ws.journals_file) or any(_has_terms(k) for k in ws.keywords_files)
    has_key = bool(
        cfg.ai.api_key or os.environ.get("LITNEXUS_API_KEY") or os.environ.get("ARK_API_KEY")
    )
    db = ws.db_path.exists()
    has_jsonl = any(ws.downloads_dir.glob("*.jsonl"))
    has_q = bool(cfg.classify.questions)
    return {
        "download": (has_terms, "" if has_terms else "请先在「配置」填写期刊或关键词"),
        "merge": (has_jsonl, "" if has_jsonl else "没有可合并的 JSONL，请先下载"),
        "translate": (db and has_key, "" if db and has_key else "需要数据库 + API Key"),
        "classify": (
            db and has_key and has_q,
            "" if db and has_key and has_q else "需要数据库 + API Key + 分类问题",
        ),
        "data": (db, "" if db else "数据库尚未创建（先下载 + 合并）"),
    }


# ── 工作区选择 ────────────────────────────────────────────────────────────────


def _reload_page() -> None:
    ui.run_javascript("window.location.reload()")


def _chooser() -> None:
    with ui.column().classes("absolute-center items-center gap-4"):
        ui.icon("biotech").classes("text-5xl").style(f"color:{DRACULA['purple']}")
        ui.label("LitNexus").classes("text-3xl font-bold")
        ui.label("选择或创建一个工作区（所有数据都集中在这个文件夹里）").classes("text-grey")
        with ui.card().classes("lit-card w-96"):
            path_in = (
                ui.input("工作区目录", value=str(Path.home() / "LitNexus"))
                .props("outlined")
                .classes("w-full")
            )

            def _open() -> None:
                try:
                    STATE.open(Path(path_in.value).expanduser())
                except Exception as e:  # noqa: BLE001
                    ui.notify(f"无法打开工作区：{e}", type="negative")
                    return
                _reload_page()

            ui.button("打开 / 创建", on_click=_open).props("color=primary unelevated").classes(
                "w-full"
            )
            recent = ws_mod.list_recent()
            if recent:
                ui.label("最近").classes("text-xs text-grey q-mt-sm")
                for r in recent[:5]:
                    ui.link(str(r), "#").on(
                        "click", lambda _, p=r: (path_in.set_value(str(p)), _open())
                    ).classes("text-xs")


def _open_workspace_dialog() -> None:
    with ui.dialog() as dialog, ui.card().classes("lit-card w-96"):
        ui.label("切换 / 新建工作区").classes("text-lg font-bold")
        path_in = (
            ui.input("工作区目录", value=str(STATE.ws.root if STATE.ws else Path.home() / "LitNexus"))
            .props("outlined")
            .classes("w-full")
        )

        def _open() -> None:
            try:
                STATE.open(Path(path_in.value).expanduser())
            except Exception as e:  # noqa: BLE001
                ui.notify(f"无法打开：{e}", type="negative")
                return
            dialog.close()
            _reload_page()

        for r in ws_mod.list_recent()[:6]:
            ui.link(str(r), "#").on("click", lambda _, p=r: path_in.set_value(str(p))).classes(
                "text-xs"
            )
        with ui.row().classes("w-full justify-end"):
            ui.button("取消", on_click=dialog.close).props("flat")
            ui.button("打开", on_click=_open).props("color=primary unelevated")
    dialog.open()


# ── 数据区（顶部，打开即见）──────────────────────────────────────────────────


def _data_section(state: _State, refreshers: list) -> None:
    ws, cfg = state.ws, state.cfg

    with ui.card().classes("lit-card w-full"):
        _section_title("数据")

        @ui.refreshable
        def stats() -> None:
            if not ws.db_path.exists():
                ui.label("数据库尚未创建——到下方「运行」执行 下载 + 合并。").classes("text-grey")
                return
            conn = db_mod.get_connection(ws.db_path, cfg)
            try:
                s = db_mod.get_stats(conn, cfg.classify.questions)
            finally:
                conn.close()
            cards = [("总文章数", "total", "purple"), ("待翻译", "pending_translation", "cyan")]
            cards += [(f"待分类 {q.id}", f"pending_{q.id}", "cyan") for q in cfg.classify.questions]
            cards += [("已收 yes", "reviewed_yes", "green"), ("已弃 no", "reviewed_no", "comment")]
            with ui.row().classes("gap-3 flex-wrap"):
                for label, key, color in cards:
                    if key in s:
                        with ui.card().classes("lit-stat items-center"):
                            ui.label(str(s[key])).classes("text-3xl font-bold").style(
                                f"color:{DRACULA.get(color, DRACULA['purple'])}"
                            )
                            ui.label(label).classes("text-xs text-grey")

        refreshers.append(stats.refresh)
        stats()
        ui.button("刷新", on_click=stats.refresh).props("flat dense").classes("q-mt-sm")

    ready = _readiness(ws, cfg)
    with ui.card().classes("lit-card w-full"):
        _section_title("导出 / 导入 CSV（复筛在 Excel 完成）")
        ui.label(f"导出范围：{cfg.export.filter}（在「配置」修改）").classes("text-sm text-grey")

        async def _export() -> None:
            res = await ng_run.io_bound(
                lambda: _do_export(state.cfg, state.ws, state.cfg.export.filter)
            )
            ui.notify(res, type="positive")
            stats.refresh()

        with ui.row().classes("items-center gap-2"):
            exp_btn = ui.button("导出 CSV", on_click=_export).props("color=primary unelevated")
            if not ready["data"][0]:
                exp_btn.props("disable")
                exp_btn.tooltip(ready["data"][1])
            ui.button("打开导出目录", on_click=lambda: _open_in_file_manager(ws.exports_dir)).props(
                "outline"
            )

        ui.separator().classes("q-my-md")
        _field_label("导入复筛结果：把在 Excel 编辑过的 CSV 拖到下面", "", state.help)

        def _on_upload(e) -> None:
            tmp = ws.exports_dir / f"_imported_{e.name}"
            try:
                tmp.write_bytes(e.content.read())
                conn = db_mod.get_connection(ws.db_path, cfg)
                try:
                    updated, unmatched, total = io_mod.import_reviewed_csv(
                        conn, tmp, cfg.schema_cfg.custom_columns
                    )
                finally:
                    conn.close()
            except Exception as exc:  # noqa: BLE001
                ui.notify(f"导入失败：{exc}", type="negative")
                return
            ui.notify(f"导入完成：更新 {updated}，未匹配 {unmatched}，共 {total} 行", type="positive")
            stats.refresh()

        ui.upload(on_upload=_on_upload, auto_upload=True, label="选择或拖入 CSV").props(
            "accept=.csv flat bordered"
        ).classes("w-full")


# ── 运行区 ────────────────────────────────────────────────────────────────────


def _run_section(state: _State, refreshers: list) -> None:
    ws = state.ws

    with ui.card().classes("lit-card w-full"):
        _section_title("运行流水线")
        with ui.row().classes("items-center gap-3 q-mb-sm"):
            mode = (
                ui.select(
                    {"all": "全部", "journals": "仅期刊", "keywords": "仅关键词"},
                    value="all",
                    label="下载模式",
                )
                .props("outlined dense")
                .classes("w-40")
            )
            days = (
                ui.number("最近 N 天", value=state.cfg.download.days, format="%d")
                .props("outlined dense")
                .classes("w-32")
            )

        log = ui.log(max_lines=600).classes("w-full h-56 lit-log q-pa-sm")

        def _refresh_all() -> None:
            for r in refreshers:
                r()
            controls.refresh()

        async def _step(name, fn, refresh=False) -> None:
            await _run_blocking(name, fn, log, _refresh_all if refresh else None)

        async def _run_all() -> None:
            cfg = state.cfg
            await _step("下载", lambda: _do_download(cfg, ws, mode.value, int(days.value or cfg.download.days)))
            await _step("合并入库", lambda: _do_merge(cfg, ws))
            await _step("翻译标题", lambda: _do_translate(cfg, ws))
            await _step("AI 分类", lambda: _do_classify(cfg, ws), refresh=True)

        @ui.refreshable
        def controls() -> None:
            cfg = state.cfg
            r = _readiness(ws, cfg)

            def btn(text, key, fn, refresh=False):
                b = ui.button(text, on_click=lambda: _step(text, fn, refresh)).props("outline")
                ok, why = r[key]
                if not ok:
                    b.props("disable")
                    if why:
                        b.tooltip(why)

            with ui.row().classes("gap-2 flex-wrap items-center"):
                btn("① 下载", "download",
                    lambda: _do_download(cfg, ws, mode.value, int(days.value or cfg.download.days)))
                btn("② 合并", "merge", lambda: _do_merge(cfg, ws), refresh=True)
                btn("③ 翻译", "translate", lambda: _do_translate(cfg, ws), refresh=True)
                btn("④ 分类", "classify", lambda: _do_classify(cfg, ws), refresh=True)
                all_btn = ui.button("▶ 一键全跑", on_click=_run_all).props("color=primary unelevated")
                if not r["download"][0]:
                    all_btn.props("disable")
                    all_btn.tooltip(r["download"][1])

        refreshers.append(controls.refresh)
        controls()


# ── 配置区 ────────────────────────────────────────────────────────────────────


def _config_section(state: _State, refreshers: list) -> None:
    cfg, ws, help_map = state.cfg, state.ws, state.help
    kw_file = ws.root / "keywords.txt"

    # 工作区 / 文件位置
    with ui.card().classes("lit-card w-full"):
        _section_title("工作区")
        for label, path in [
            ("配置文件", ws.config_path),
            ("数据库", ws.db_path),
            ("下载目录", ws.downloads_dir),
            ("导出目录", ws.exports_dir),
            ("提示文案 help.toml", _HELP_FILE),
        ]:
            with ui.row().classes("items-center gap-2 no-wrap w-full"):
                ui.label(label).classes("text-sm text-grey").style("min-width:140px")
                ui.label(str(path)).classes("text-sm").style("font-family:monospace")
        with ui.row().classes("q-mt-sm gap-2"):
            ui.button("切换 / 新建工作区", on_click=_open_workspace_dialog).props("outline")
            ui.button("打开工作区目录", on_click=lambda: _open_in_file_manager(ws.root)).props("flat")

    # 检索列表
    with ui.card().classes("lit-card w-full"):
        _section_title("检索列表")
        _field_label("期刊", "journals", help_map)
        journals_ta = (
            ui.textarea(value=_read_text(ws.journals_file))
            .props("outlined autogrow")
            .classes("w-full")
        )
        _field_label("关键词检索式", "keywords", help_map)
        keywords_ta = ui.textarea(value=_read_text(kw_file)).props("outlined autogrow").classes("w-full")
        extra_kw = [p for p in ws.keywords_files if p != kw_file and p.exists()]
        if extra_kw:
            ui.label(
                f"另有 {len(extra_kw)} 个 keywords/*.txt 文件（{', '.join(p.name for p in extra_kw)}）"
                "也会用于下载，但此处仅编辑根目录的 keywords.txt。"
            ).classes("text-xs text-grey")

    # AI
    with ui.card().classes("lit-card w-full"):
        _section_title("AI 接口")
        _field_label("Base URL", "base_url", help_map)
        base_url = ui.input(value=cfg.ai.base_url).props("outlined dense").classes("w-full")
        _field_label("模型名", "model", help_map)
        model = ui.input(value=cfg.ai.model).props("outlined dense").classes("w-full")
        _field_label("API Key", "api_key", help_map)
        api_key = (
            ui.input(value=cfg.ai.api_key, password=True, password_toggle_button=True)
            .props("outlined dense")
            .classes("w-full")
        )

        async def _test() -> None:
            key = api_key.value.strip() or os.environ.get("LITNEXUS_API_KEY") or os.environ.get(
                "ARK_API_KEY"
            )
            if not key:
                ui.notify("未填写 API Key", type="warning")
                return

            def _check() -> str:
                from openai import OpenAI

                client = OpenAI(api_key=key, base_url=base_url.value.strip())
                client.chat.completions.create(
                    model=model.value.strip(),
                    messages=[{"role": "user", "content": "ping"}],
                    max_tokens=1,
                )
                return "ok"

            ui.notify("测试中…")
            try:
                await ng_run.io_bound(_check)
                ui.notify("连接成功", type="positive")
            except Exception as e:  # noqa: BLE001
                ui.notify(f"连接失败：{e}", type="negative")

        ui.button("测试连接", on_click=_test).props("outline").classes("q-mt-sm")

    # 分类问题
    questions: list[dict] = [{"id": q.id, "text": q.text} for q in cfg.classify.questions]

    def _sync_questions() -> None:
        for q in questions:
            if "_id_w" in q:
                q["id"] = q["_id_w"].value
            if "_text_w" in q:
                q["text"] = q["_text_w"].value

    with ui.card().classes("lit-card w-full"):
        with ui.row().classes("items-center gap-1 q-mb-sm"):
            _section_title("分类问题（AI 初筛 Prompt）")
            tip = help_map.get("questions")
            if tip:
                ui.icon("help_outline").classes("cursor-help").style("opacity:.55").tooltip(tip)

        @ui.refreshable
        def q_list() -> None:
            for i, q in enumerate(questions):
                with ui.card().classes("w-full").style("border-radius:12px"):
                    with ui.row().classes("w-full items-center no-wrap"):
                        q["_id_w"] = ui.input("列名 id", value=q["id"]).props("outlined dense").classes("w-40")
                        ui.space()
                        ui.button(icon="delete", on_click=lambda _, idx=i: _del(idx)).props(
                            "flat round color=negative dense"
                        )
                    q["_text_w"] = (
                        ui.textarea("问题描述", value=q["text"]).props("outlined autogrow").classes("w-full")
                    )

        def _del(idx: int) -> None:
            _sync_questions()
            questions.pop(idx)
            q_list.refresh()

        def _add() -> None:
            _sync_questions()
            questions.append({"id": f"q{len(questions) + 1}", "text": ""})
            q_list.refresh()

        q_list()
        ui.button("+ 新增问题", on_click=_add).props("outline")

    # 数据库列（chips）
    with ui.card().classes("lit-card w-full"):
        _section_title("数据库列")
        _field_label("标注列（复筛时人工填写）", "annotation_columns", help_map)
        ann = (
            ui.select(
                options=list(cfg.schema_cfg.custom_columns),
                value=list(cfg.schema_cfg.custom_columns),
                multiple=True,
                new_value_mode="add-unique",
            )
            .props("outlined use-chips dense")
            .classes("w-full")
        )
        _field_label("额外抓取的 EPMC 字段", "extra_fields", help_map)
        extra_checks: dict[str, ui.checkbox] = {}
        with ui.row().classes("w-full flex-wrap"):
            for fid, desc in fields_mod.available_extra_fields():
                extra_checks[fid] = ui.checkbox(desc, value=fid in cfg.ingest.extra_fields)

    # 参数与导出
    with ui.card().classes("lit-card w-full"):
        _section_title("参数与导出筛选")
        with ui.row().classes("w-full gap-3 flex-wrap"):
            with ui.column().classes("gap-0"):
                _field_label("下载最近 N 天", "days", help_map)
                days_in = ui.number(value=cfg.download.days, format="%d").props("outlined dense")
            with ui.column().classes("gap-0"):
                _field_label("page_size", "page_size", help_map)
                page_size = ui.number(value=cfg.download.page_size, format="%d").props("outlined dense")
            with ui.column().classes("gap-0"):
                _field_label("请求间隔(秒)", "request_delay", help_map)
                delay = ui.number(value=cfg.download.request_delay).props("outlined dense")
        with ui.row().classes("w-full gap-3 flex-wrap"):
            with ui.column().classes("gap-0"):
                _field_label("翻译批量", "batch_size", help_map)
                batch = ui.number(value=cfg.translate.batch_size, format="%d").props("outlined dense")
            with ui.column().classes("gap-0"):
                _field_label("翻译并发", "concurrency", help_map)
                conc = ui.number(value=cfg.translate.concurrency, format="%d").props("outlined dense")
            with ui.column().classes("gap-0"):
                _field_label("分类并发", "max_workers", help_map)
                workers = ui.number(value=cfg.classify.max_workers, format="%d").props("outlined dense")
        _field_label("导出筛选", "export_filter", help_map)
        exp_filter = ui.input(value=cfg.export.filter).props("outlined dense").classes("w-full")
        _field_label("导出排除列", "exclude_columns", help_map)
        exclude = (
            ui.select(
                options=list(cfg.export.exclude_columns),
                value=list(cfg.export.exclude_columns),
                multiple=True,
                new_value_mode="add-unique",
            )
            .props("outlined use-chips dense")
            .classes("w-full")
        )

    # 外观 / 品牌
    with ui.card().classes("lit-card w-full"):
        _section_title("外观")
        ui.label(f"Logo：把图片保存为 {ws.root / 'logo.png'} 即自动显示，或下面上传。").classes(
            "text-sm text-grey"
        )

        def _on_logo(e) -> None:
            try:
                (ws.root / "logo.png").write_bytes(e.content.read())
            except OSError as exc:
                ui.notify(f"保存失败：{exc}", type="negative")
                return
            ui.notify("Logo 已保存，刷新页面生效", type="positive")

        ui.upload(on_upload=_on_logo, auto_upload=True, label="上传 Logo").props(
            "accept=image/* flat bordered"
        ).classes("w-full")

    def _save() -> None:
        _sync_questions()
        cfg.ai.base_url = base_url.value.strip()
        cfg.ai.model = model.value.strip()
        cfg.ai.api_key = api_key.value.strip()
        cfg.download.days = int(days_in.value or 30)
        cfg.download.page_size = int(page_size.value or 1000)
        cfg.download.request_delay = float(delay.value or 0.5)
        cfg.translate.batch_size = int(batch.value or 30)
        cfg.translate.concurrency = int(conc.value or 20)
        cfg.classify.max_workers = int(workers.value or 100)
        cfg.classify.questions = [
            Question(id=q["id"].strip(), text=q["text"].strip()) for q in questions if q["id"].strip()
        ]
        cfg.schema_cfg.custom_columns = [c.strip() for c in (ann.value or []) if c.strip()]
        cfg.ingest.extra_fields = [fid for fid, cb in extra_checks.items() if cb.value]
        cfg.export.filter = exp_filter.value.strip() or "pending"
        cfg.export.exclude_columns = [c.strip() for c in (exclude.value or []) if c.strip()]
        try:
            save_config(cfg, ws.config_path)
            ws.journals_file.write_text(journals_ta.value, encoding="utf-8")
            kw_file.write_text(keywords_ta.value, encoding="utf-8")
            db_mod.get_connection(ws.db_path, cfg).close()
            state.reload()
            for r in refreshers:
                r()
            ui.notify("配置已保存", type="positive")
        except Exception as e:  # noqa: BLE001
            ui.notify(f"保存失败：{e}", type="negative")

    ui.button("保存配置", on_click=_save).props("color=primary unelevated size=lg").classes("q-mb-xl")


# ── 顶栏 + 页面 ───────────────────────────────────────────────────────────────


def _header(state: _State, dark) -> None:
    with ui.header(elevated=False).classes("lit-header items-center q-px-md"):
        _logo(state.ws)
        ui.label("LitNexus").classes("text-lg font-bold q-ml-sm")
        ui.space()
        with ui.row().classes("items-center gap-5"):
            ui.link("数据", "#data").classes("lit-nav")
            ui.link("运行", "#run").classes("lit-nav")
            ui.link("配置", "#config").classes("lit-nav")
        ui.space()

        def _toggle() -> None:
            dark.toggle()
            nicegui_app.storage.user["theme"] = "dark" if dark.value else "light"

        ui.button(icon="contrast", on_click=_toggle).props("flat round dense").tooltip(
            "切换深色 / 浅色"
        )
        ui.button(icon="folder_open", on_click=_open_workspace_dialog).props("flat round dense").tooltip(
            "切换工作区"
        )


@ui.page("/")
def _index() -> None:
    ui.colors(
        primary=DRACULA["purple"],
        secondary=DRACULA["comment"],
        accent=DRACULA["pink"],
        positive=DRACULA["green"],
        negative=DRACULA["red"],
        info=DRACULA["cyan"],
        warning=DRACULA["yellow"],
    )
    ui.add_css(APP_CSS)
    dark = ui.dark_mode(value=(nicegui_app.storage.user.get("theme", "dark") == "dark"))

    if STATE.ws is None or STATE.cfg is None:
        _chooser()
        return

    STATE.help = _load_help()
    _header(STATE, dark)
    refreshers: list = []
    with ui.column().classes("lit-main"):
        ui.link_target("data")
        _data_section(STATE, refreshers)
        ui.link_target("run")
        _run_section(STATE, refreshers)
        ui.link_target("config")
        _config_section(STATE, refreshers)


def launch(
    workspace: Path | None = None,
    *,
    native: bool = False,
    port: int = 8080,
    show: bool = True,
) -> None:
    """启动 GUI。优先打开指定/活动工作区，否则进入工作区选择页。"""
    try:
        ws = ws_mod.resolve_workspace(workspace)
        STATE.ws = ws
        STATE.cfg = load_config(ws.config_path)
    except WorkspaceError:
        pass

    ui.run(
        title="LitNexus",
        native=native,
        port=port,
        reload=False,
        show=show,
        storage_secret="litnexus-gui",
    )

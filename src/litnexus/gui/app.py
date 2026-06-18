"""LitNexus 桌面应用（NiceGUI，v3）。

信息架构：左侧边栏 + 三个独立子页（运行 / 数据 / 配置）。
- 无工作区时进「项目选择」（打开已有 / 新建到默认位置）。
- 全新工作区（AI 未配置）先进「首次设置向导」：检索列表 → AI 接口。
- 已就绪则直接进「运行」主页。

配色为石墨黑 + 靓蓝（Linear 风），暗色为默认，可切浅色。
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
from litnexus.core import io as io_mod
from litnexus.core import pipeline as pipeline_mod
from litnexus.core import translator as trans_mod
from litnexus.core import workspace as ws_mod
from litnexus.core.classifier import run_classification
from litnexus.core.config import Config, Question, load_config, resolved_ai
from litnexus.core.config_saver import save_config
from litnexus.core.workspace import Workspace, WorkspaceError

logger = logging.getLogger(__name__)

# ── 配色（石墨黑 + 靓蓝）──────────────────────────────────────────────────────
# 暗色为主、亮色为辅，用 CSS 变量按 body--dark / body--light 切换。

ACCENT_DARK = "#6366F1"  # indigo，暗色下的强调色
ACCENT_LIGHT = "#4F46E5"  # 亮色下等视觉强度的强调色
GREEN = "#10B981"
AMBER = "#F59E0B"
RED = "#EF4444"
CYAN = "#22D3EE"

APP_CSS = f"""
:root {{ --lit-radius: 12px; }}

.body--dark {{
    --bg: #0A0A0B; --panel: #18181B; --panel2: #1F1F23; --line: #27272A;
    --fg: #FAFAFA; --muted: #A1A1AA; --accent: {ACCENT_DARK};
}}
.body--light {{
    --bg: #FAFAFA; --panel: #FFFFFF; --panel2: #F4F4F5; --line: #E4E4E7;
    --fg: #18181B; --muted: #71717A; --accent: {ACCENT_LIGHT};
}}

body, .q-page, .nicegui-content {{
    background: var(--bg); color: var(--fg);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC",
                 "Microsoft YaHei", Roboto, system-ui, sans-serif;
    -webkit-font-smoothing: antialiased;
}}
.nicegui-content {{ padding: 0; }}

.lit-main {{ width: 100%; max-width: 880px; margin: 0 auto;
    padding: 32px 28px 96px; gap: 18px; }}
.lit-page-title {{ font-size: 1.55rem; font-weight: 700; letter-spacing: -.02em; }}
.lit-page-sub {{ color: var(--muted); font-size: .9rem; margin-top: -2px; }}

.lit-card {{
    background: var(--panel); border: 1px solid var(--line);
    border-radius: var(--lit-radius); padding: 20px 22px;
}}
.lit-section-title {{ font-size: 1.05rem; font-weight: 650; letter-spacing: -.01em; }}
.lit-stat {{
    background: var(--panel2); border: 1px solid var(--line);
    border-radius: var(--lit-radius); min-width: 124px; padding: 14px 16px;
}}
.lit-log {{
    background: #000; color: #E4E4E7; border-radius: 10px;
    font-family: "SF Mono", ui-monospace, Menlo, monospace; font-size: 12px;
}}

/* 侧边栏 */
.lit-drawer {{ background: var(--panel); border-right: 1px solid var(--line); }}
.lit-brand {{ font-weight: 750; letter-spacing: -.01em; font-size: 1.05rem; }}
.lit-nav {{
    display: flex; align-items: center; gap: 10px; width: 100%;
    padding: 9px 12px; border-radius: 10px; cursor: pointer;
    color: var(--muted); font-weight: 550; font-size: .92rem;
    transition: background .12s, color .12s;
}}
.lit-nav:hover {{ background: var(--panel2); color: var(--fg); }}
.lit-nav-active {{ background: var(--panel2); color: var(--fg); }}
.lit-nav-active .q-icon {{ color: var(--accent); }}
.lit-ws-name {{ font-size: .8rem; color: var(--muted); word-break: break-all; }}
"""

# ── 字段提示（可编辑的 help.toml）─────────────────────────────────────────────

_HELP_FILE = Path(platformdirs.user_config_dir(ws_mod.APP_NAME)) / "help.toml"

DEFAULT_HELP_TOML = """\
# LitNexus 字段提示文案（GUI 里 ? 悬停显示）。可自由编辑，保存后刷新页面生效。
[help]
journals = "每行一个期刊名，需与 Europe PMC 中的名称完全一致；# 开头为注释。例：Nature"
keywords = "每行一个检索式，支持 Europe PMC 布尔语法。例：(microbiome OR microbiota) AND \\"machine learning\\""
base_url = "AI 服务的 OpenAI 兼容接口地址，需填你自己服务商的完整 URL（无默认值）。"
model = "要调用的模型名称，需与服务商提供的完全一致（无默认值）。"
api_key = "API 密钥。留空则读取环境变量 LITNEXUS_API_KEY 或 ARK_API_KEY，避免写入文件。"
questions = "AI 初筛问题：每条一个，AI 对每篇文章回答是/否；id 会成为数据库列名（{id}_ans / {id}_rea）。"
annotation_columns = "复筛时人工填写的列（导出到 CSV 里手动标记）。include 用于筛选与统计（yes/no），可再加 tags、priority、notes 等。"
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


# 模块级单例：本应用按「单用户、单实例」使用。多个浏览器标签共享同一 STATE/工作区。
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


def _default_ws_path() -> Path:
    """新建项目的默认位置：~/Documents/LitNexus（Documents 不存在则退回 ~/LitNexus）。"""
    docs = Path.home() / "Documents"
    base = docs if docs.is_dir() else Path.home()
    return base / "LitNexus"


def _needs_setup(cfg: Config) -> bool:
    """工作区是否还没过首次设置：以「AI 接口未配置」为信号（无默认值，必须用户填）。"""
    return not (cfg.ai.base_url.strip() and cfg.ai.model.strip())


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


async def _pick_folder(default: str = "") -> str | None:
    """原生窗口下弹系统目录选择框；浏览器模式返回 None（让用户手敲路径）。"""
    try:
        win = getattr(nicegui_app.native, "main_window", None)
        if win is None:
            return None
        import webview

        result = await win.create_file_dialog(webview.FOLDER_DIALOG, directory=default or "")
        if not result:
            return None
        return result[0] if isinstance(result, (list, tuple)) else str(result)
    except Exception:  # noqa: BLE001 —— 任何失败都安静退回手敲
        return None


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
    """把核心模块的进度上报转成节流的 logging，让 GUI 日志面板能看到百分比进度。"""

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
        "download": (has_terms, "" if has_terms else "请先到「配置」填写期刊或关键词"),
        "merge": (has_jsonl, "" if has_jsonl else "没有可合并的 JSONL，请先下载"),
        "translate": (db and has_key, "" if db and has_key else "需要数据库 + API Key"),
        "classify": (
            db and has_key and has_q,
            "" if db and has_key and has_q else "需要数据库 + API Key + 分类问题",
        ),
        "data": (db, "" if db else "数据库尚未创建（先下载 + 合并）"),
    }


def _go_after_open() -> None:
    """打开/新建项目后，按是否需要首次设置跳到对应页（用确定路径避免重载循环）。"""
    ui.navigate.to("/setup" if _needs_setup(STATE.cfg) else "/run")


# ── 项目选择（无工作区时）─────────────────────────────────────────────────────


def _chooser() -> None:
    with ui.column().classes("absolute-center items-center gap-4").style("width:420px"):
        ui.icon("biotech").classes("text-5xl").style(f"color:{ACCENT_DARK}")
        ui.label("LitNexus").classes("text-3xl font-bold")
        ui.label("选择一个项目文件夹——所有数据都集中在里面").classes("text-grey text-center")

        with ui.card().classes("lit-card w-full"):
            path_in = (
                ui.input("项目文件夹", value=str(_default_ws_path()))
                .props("outlined dense")
                .classes("w-full")
            )

            async def _browse() -> None:
                picked = await _pick_folder(path_in.value)
                if picked:
                    path_in.set_value(picked)
                elif getattr(nicegui_app.native, "main_window", None) is None:
                    ui.notify("浏览器模式无法弹文件框，请直接在上面输入路径", type="info")

            def _open() -> None:
                try:
                    STATE.open(Path(path_in.value).expanduser())
                except Exception as e:  # noqa: BLE001
                    ui.notify(f"无法打开项目：{e}", type="negative")
                    return
                _go_after_open()

            with ui.row().classes("w-full gap-2 q-mt-sm"):
                ui.button("浏览…", on_click=_browse).props("outline").classes("col-auto")
                ui.button("打开 / 新建", on_click=_open).props("color=primary unelevated").classes(
                    "col"
                )
            ui.label("文件夹已存在就打开，不存在就新建。").classes("text-xs text-grey q-mt-xs")

            recent = ws_mod.list_recent()
            if recent:
                ui.separator().classes("q-my-sm")
                ui.label("最近打开").classes("text-xs text-grey")
                for r in recent[:5]:
                    ui.link(str(r), "#").on(
                        "click", lambda _, p=r: (path_in.set_value(str(p)), _open())
                    ).classes("text-xs")


# ── 首次设置向导 ──────────────────────────────────────────────────────────────


def _setup_wizard(state: _State) -> None:
    ws, cfg = state.ws, state.cfg
    help_map = state.help
    kw_file = ws.root / ws_mod.KEYWORDS_FILENAME

    with ui.column().classes("absolute-center").style("width:680px;max-width:92vw"):
        with ui.row().classes("items-center gap-2 q-mb-sm"):
            ui.icon("rocket_launch").style(f"color:{ACCENT_DARK};font-size:28px")
            ui.label("首次设置").classes("text-2xl font-bold")
        ui.label(f"项目：{ws.root}").classes("lit-ws-name q-mb-md")

        with ui.stepper().props("vertical flat").classes("w-full") as stepper:
            with ui.step("检索列表"):
                ui.label("决定抓哪些文章。已为你预填示例，按需修改即可。").classes(
                    "text-sm text-grey q-mb-sm"
                )
                _field_label("期刊（每行一个）", "journals", help_map)
                journals_ta = (
                    ui.textarea(value=_read_text(ws.journals_file))
                    .props("outlined autogrow")
                    .classes("w-full")
                )
                _field_label("关键词检索式（每行一个）", "keywords", help_map)
                keywords_ta = (
                    ui.textarea(value=_read_text(kw_file)).props("outlined autogrow").classes("w-full")
                )
                with ui.stepper_navigation():
                    ui.button("下一步", on_click=stepper.next).props("color=primary unelevated")

            with ui.step("AI 接口"):
                ui.label("翻译与分类需要一个 OpenAI 兼容接口。无默认值，请填你自己的。").classes(
                    "text-sm text-grey q-mb-sm"
                )
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
                    await _test_ai_connection(api_key.value, base_url.value, model.value)

                with ui.row().classes("items-center gap-2 q-mt-sm"):
                    ui.button("测试连接", on_click=_test).props("outline")
                with ui.stepper_navigation():
                    ui.button("上一步", on_click=stepper.previous).props("flat")

                    def _finish() -> None:
                        cfg.ai.base_url = base_url.value.strip()
                        cfg.ai.model = model.value.strip()
                        cfg.ai.api_key = api_key.value.strip()
                        try:
                            ws.journals_file.write_text(journals_ta.value, encoding="utf-8")
                            kw_file.write_text(keywords_ta.value, encoding="utf-8")
                            save_config(cfg, ws.config_path)
                            state.reload()
                        except Exception as e:  # noqa: BLE001
                            ui.notify(f"保存失败：{e}", type="negative")
                            return
                        ui.navigate.to("/")

                    ui.button("完成，开始使用", on_click=_finish).props("color=primary unelevated")

        ui.button("跳过，直接进入", on_click=lambda: ui.navigate.to("/run")).props(
            "flat size=sm"
        ).classes("q-mt-sm self-center")


async def _test_ai_connection(key_val: str, base_url_val: str, model_val: str) -> None:
    key = key_val.strip() or os.environ.get("LITNEXUS_API_KEY") or os.environ.get("ARK_API_KEY")
    if not key:
        ui.notify("未填写 API Key", type="warning")
        return
    if not base_url_val.strip() or not model_val.strip():
        ui.notify("请先填写 Base URL 和模型名", type="warning")
        return

    def _check() -> str:
        from openai import OpenAI

        client = OpenAI(api_key=key, base_url=base_url_val.strip())
        client.chat.completions.create(
            model=model_val.strip(),
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


# ── 应用外壳（侧边栏 + 主题）──────────────────────────────────────────────────

_NAV = [("运行", "play_circle", "/run"), ("数据", "database", "/data"), ("配置", "settings", "/settings")]


def _apply_theme():
    ui.colors(
        primary=ACCENT_DARK,
        secondary="#52525B",
        accent=ACCENT_DARK,
        positive=GREEN,
        negative=RED,
        info=CYAN,
        warning=AMBER,
    )
    ui.add_css(APP_CSS)
    return ui.dark_mode(value=(nicegui_app.storage.user.get("theme", "dark") == "dark"))


def _sidebar(active: str, dark) -> None:
    with ui.left_drawer(fixed=True, bordered=False).props("width=212").classes("lit-drawer q-pa-md"):
        with ui.row().classes("items-center gap-2 q-mb-lg"):
            ui.icon("biotech").style(f"color:{ACCENT_DARK};font-size:22px")
            ui.label("LitNexus").classes("lit-brand")

        for label, icon, path in _NAV:
            cls = "lit-nav lit-nav-active" if path == active else "lit-nav"
            with ui.element("div").classes(cls).on("click", lambda _, p=path: ui.navigate.to(p)):
                ui.icon(icon).style("font-size:18px")
                ui.label(label)

        ui.space()
        ui.separator()
        with ui.column().classes("gap-1 q-mt-sm w-full"):
            ui.label("当前项目").classes("text-xs text-grey")
            ui.label(STATE.ws.root.name).classes("lit-ws-name")
            with ui.row().classes("gap-1 q-mt-xs"):

                def _toggle() -> None:
                    dark.toggle()
                    nicegui_app.storage.user["theme"] = "dark" if dark.value else "light"

                ui.button(icon="contrast", on_click=_toggle).props("flat round dense").tooltip(
                    "切换深 / 浅色"
                )
                ui.button(
                    icon="folder_open", on_click=lambda: _open_in_file_manager(STATE.ws.root)
                ).props("flat round dense").tooltip("打开项目目录")
                ui.button(icon="swap_horiz", on_click=lambda: ui.navigate.to("/?switch=1")).props(
                    "flat round dense"
                ).tooltip("切换项目")


def _page_header(title: str, subtitle: str) -> None:
    with ui.column().classes("gap-0 q-mb-sm"):
        ui.label(title).classes("lit-page-title")
        ui.label(subtitle).classes("lit-page-sub")


# ── 运行页 ────────────────────────────────────────────────────────────────────


def _run_page(state: _State) -> None:
    ws = state.ws
    _page_header("运行", "下载 → 合并 → 翻译 → 分类，一条流水线跑到底")

    with ui.card().classes("lit-card w-full"):
        _section_title("检索范围")
        with ui.row().classes("items-center gap-3 q-mb-md"):
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

        log = ui.log(max_lines=600).classes("w-full h-64 lit-log q-pa-sm q-mb-md")

        async def _step(name, fn, refresh=False) -> None:
            await _run_blocking(name, fn, log, controls.refresh if refresh else None)

        async def _run_all() -> None:
            cfg = state.cfg
            d = int(days.value or cfg.download.days)
            await _step("下载", lambda: _do_download(cfg, ws, mode.value, d))
            await _step("合并入库", lambda: _do_merge(cfg, ws))
            await _step("翻译标题", lambda: _do_translate(cfg, ws))
            await _step("AI 分类", lambda: _do_classify(cfg, ws), refresh=True)

        @ui.refreshable
        def controls() -> None:
            cfg = state.cfg
            r = _readiness(ws, cfg)
            d = lambda: int(days.value or cfg.download.days)  # noqa: E731

            with ui.row().classes("gap-2 flex-wrap items-center"):
                all_btn = ui.button("▶ 一键全跑", on_click=_run_all).props(
                    "color=primary unelevated"
                )
                if not r["download"][0]:
                    all_btn.props("disable")
                    all_btn.tooltip(r["download"][1])

                def btn(text, key, fn, refresh=False):
                    b = ui.button(text, on_click=lambda: _step(text, fn, refresh)).props("outline")
                    ok, why = r[key]
                    if not ok:
                        b.props("disable")
                        if why:
                            b.tooltip(why)

                btn("① 下载", "download", lambda: _do_download(cfg, ws, mode.value, d()))
                btn("② 合并", "merge", lambda: _do_merge(cfg, ws), refresh=True)
                btn("③ 翻译", "translate", lambda: _do_translate(cfg, ws), refresh=True)
                btn("④ 分类", "classify", lambda: _do_classify(cfg, ws), refresh=True)

        controls()
        ui.label("跑完后到「数据」页查看统计并导出。").classes("text-xs text-grey q-mt-sm")


# ── 数据页 ────────────────────────────────────────────────────────────────────


def _data_page(state: _State) -> None:
    ws, cfg = state.ws, state.cfg
    _page_header("数据", "库内统计、导出复筛 CSV、导回人工标注")

    with ui.card().classes("lit-card w-full"):
        _section_title("统计")

        @ui.refreshable
        def stats() -> None:
            if not ws.db_path.exists():
                ui.label("数据库尚未创建——先到「运行」执行下载 + 合并。").classes("text-grey")
                return
            conn = db_mod.get_connection(ws.db_path, cfg)
            try:
                s = db_mod.get_stats(conn, cfg.classify.questions)
            finally:
                conn.close()
            cards = [("总文章数", "total", ACCENT_DARK), ("待翻译", "pending_translation", CYAN)]
            cards += [(f"待分类 {q.id}", f"pending_{q.id}", CYAN) for q in cfg.classify.questions]
            cards += [("已收 yes", "reviewed_yes", GREEN), ("已弃 no", "reviewed_no", "#A1A1AA")]
            with ui.row().classes("gap-3 flex-wrap"):
                for label, key, color in cards:
                    if key in s:
                        with ui.card().classes("lit-stat items-center"):
                            ui.label(str(s[key])).classes("text-3xl font-bold").style(
                                f"color:{color}"
                            )
                            ui.label(label).classes("text-xs text-grey")

        stats()
        ui.button("刷新", on_click=stats.refresh).props("flat dense").classes("q-mt-sm")

    ready = _readiness(ws, cfg)
    with ui.card().classes("lit-card w-full"):
        _section_title("导出 CSV")
        with ui.row().classes("items-center gap-3 q-mb-sm"):
            exp_filter = (
                ui.select(
                    {"pending": "未复筛 (pending)", "all": "全部 (all)"},
                    value=cfg.export.filter if cfg.export.filter in ("pending", "all") else "pending",
                    label="导出范围",
                )
                .props("outlined dense")
                .classes("w-52")
            )

        async def _export() -> None:
            res = await ng_run.io_bound(lambda: _do_export(state.cfg, state.ws, exp_filter.value))
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

    with ui.card().classes("lit-card w-full"):
        _section_title("导入复筛结果")
        ui.label("把在 Excel 编辑过的 CSV 拖到下面，标注会写回数据库。").classes(
            "text-sm text-grey q-mb-sm"
        )

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


# ── 配置页 ────────────────────────────────────────────────────────────────────


def _settings_page(state: _State) -> None:
    cfg, ws, help_map = state.cfg, state.ws, state.help
    kw_file = ws.root / ws_mod.KEYWORDS_FILENAME
    _page_header("配置", "检索范围、AI 接口、初筛问题，以及不常动的高级项")

    # 检索列表（最常改，置顶）
    with ui.card().classes("lit-card w-full"):
        _section_title("检索列表")
        _field_label("期刊", "journals", help_map)
        journals_ta = (
            ui.textarea(value=_read_text(ws.journals_file))
            .props("outlined autogrow")
            .classes("w-full")
        )
        _field_label("关键词检索式", "keywords", help_map)
        keywords_ta = (
            ui.textarea(value=_read_text(kw_file)).props("outlined autogrow").classes("w-full")
        )
        extra_kw = [p for p in ws.keywords_files if p != kw_file and p.exists()]
        if extra_kw:
            ui.label(
                f"另有 {len(extra_kw)} 个 keywords/*.txt 也会用于下载（{', '.join(p.name for p in extra_kw)}），"
                "此处仅编辑根目录的 keywords.txt。"
            ).classes("text-xs text-grey")

    # AI 接口
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
            await _test_ai_connection(api_key.value, base_url.value, model.value)

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
                with ui.card().classes("w-full").style("border-radius:10px"):
                    with ui.row().classes("w-full items-center no-wrap"):
                        q["_id_w"] = (
                            ui.input("列名 id", value=q["id"]).props("outlined dense").classes("w-40")
                        )
                        ui.space()
                        ui.button(icon="delete", on_click=lambda _, idx=i: _del(idx)).props(
                            "flat round color=negative dense"
                        )
                    q["_text_w"] = (
                        ui.textarea("问题描述", value=q["text"])
                        .props("outlined autogrow")
                        .classes("w-full")
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

    # 高级（默认折叠）
    with ui.card().classes("lit-card w-full"):
        with ui.expansion("高级参数").classes("w-full").props("dense"):
            with ui.row().classes("w-full gap-3 flex-wrap q-mt-sm"):
                with ui.column().classes("gap-0"):
                    _field_label("下载最近 N 天", "days", help_map)
                    days_in = ui.number(value=cfg.download.days, format="%d").props("outlined dense")
                with ui.column().classes("gap-0"):
                    _field_label("page_size", "page_size", help_map)
                    page_size = ui.number(value=cfg.download.page_size, format="%d").props(
                        "outlined dense"
                    )
                with ui.column().classes("gap-0"):
                    _field_label("请求间隔(秒)", "request_delay", help_map)
                    delay = ui.number(value=cfg.download.request_delay).props("outlined dense")
            with ui.row().classes("w-full gap-3 flex-wrap"):
                with ui.column().classes("gap-0"):
                    _field_label("翻译批量", "batch_size", help_map)
                    batch = ui.number(value=cfg.translate.batch_size, format="%d").props(
                        "outlined dense"
                    )
                with ui.column().classes("gap-0"):
                    _field_label("翻译并发", "concurrency", help_map)
                    conc = ui.number(value=cfg.translate.concurrency, format="%d").props(
                        "outlined dense"
                    )
                with ui.column().classes("gap-0"):
                    _field_label("分类并发", "max_workers", help_map)
                    workers = ui.number(value=cfg.classify.max_workers, format="%d").props(
                        "outlined dense"
                    )
            _field_label("导出筛选（默认范围）", "export_filter", help_map)
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
            _field_label("人工标注列", "annotation_columns", help_map)
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

    # 工作区信息（折叠，最底部——设一次就不动）
    with ui.card().classes("lit-card w-full"):
        with ui.expansion("项目位置 / 文件").classes("w-full").props("dense"):
            for label, path in [
                ("配置文件", ws.config_path),
                ("数据库", ws.db_path),
                ("下载目录", ws.downloads_dir),
                ("导出目录", ws.exports_dir),
                ("提示文案 help.toml", _HELP_FILE),
            ]:
                with ui.row().classes("items-center gap-2 no-wrap w-full q-mt-xs"):
                    ui.label(label).classes("text-sm text-grey").style("min-width:140px")
                    ui.label(str(path)).classes("text-sm").style("font-family:monospace")
            with ui.row().classes("q-mt-sm gap-2"):
                ui.button("切换项目", on_click=lambda: ui.navigate.to("/?switch=1")).props("outline")
                ui.button("打开项目目录", on_click=lambda: _open_in_file_manager(ws.root)).props(
                    "flat"
                )

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
            Question(id=q["id"].strip(), text=q["text"].strip())
            for q in questions
            if q["id"].strip()
        ]
        cfg.schema_cfg.custom_columns = [c.strip() for c in (ann.value or []) if c.strip()]
        cfg.export.filter = exp_filter.value.strip() or "pending"
        cfg.export.exclude_columns = [c.strip() for c in (exclude.value or []) if c.strip()]
        try:
            save_config(cfg, ws.config_path)
            ws.journals_file.write_text(journals_ta.value, encoding="utf-8")
            kw_file.write_text(keywords_ta.value, encoding="utf-8")
            db_mod.get_connection(ws.db_path, cfg).close()
            state.reload()
            ui.notify("配置已保存", type="positive")
        except Exception as e:  # noqa: BLE001
            ui.notify(f"保存失败：{e}", type="negative")

    ui.button("保存配置", on_click=_save).props("color=primary unelevated size=lg").classes(
        "q-mt-sm q-mb-xl"
    )


# ── 路由 ──────────────────────────────────────────────────────────────────────


def _ensure_workspace_or_redirect() -> bool:
    """主页之外的页若无工作区则回首页。返回 True 表示工作区就绪。"""
    if STATE.ws is None or STATE.cfg is None:
        ui.navigate.to("/")
        return False
    STATE.help = _load_help()
    return True


@ui.page("/")
def _index(switch: int = 0) -> None:
    _apply_theme()
    # 显式切换项目：清空状态回到选择页。
    if switch:
        STATE.ws = None
        STATE.cfg = None
    if STATE.ws is None or STATE.cfg is None:
        _chooser()
        return
    STATE.help = _load_help()
    ui.navigate.to("/setup" if _needs_setup(STATE.cfg) else "/run")


@ui.page("/setup")
def _page_setup() -> None:
    _apply_theme()
    if not _ensure_workspace_or_redirect():
        return
    _setup_wizard(STATE)


@ui.page("/run")
def _page_run() -> None:
    dark = _apply_theme()
    if not _ensure_workspace_or_redirect():
        return
    _sidebar("/run", dark)
    with ui.column().classes("lit-main"):
        _run_page(STATE)


@ui.page("/data")
def _page_data() -> None:
    dark = _apply_theme()
    if not _ensure_workspace_or_redirect():
        return
    _sidebar("/data", dark)
    with ui.column().classes("lit-main"):
        _data_page(STATE)


@ui.page("/settings")
def _page_settings() -> None:
    dark = _apply_theme()
    if not _ensure_workspace_or_redirect():
        return
    _sidebar("/settings", dark)
    with ui.column().classes("lit-main"):
        _settings_page(STATE)


# ── 启动 ──────────────────────────────────────────────────────────────────────


def launch(
    workspace: Path | None = None,
    *,
    native: bool = False,
    port: int = 8080,
    show: bool = True,
) -> None:
    """启动 GUI。优先打开指定/活动工作区，否则进入项目选择页。

    native=True 时尝试原生桌面窗口（pywebview）；若所在系统缺少 WebView 运行时
    导致原生窗口起不来，会自动回退到浏览器模式，避免窗口版「双击没反应」。
    """
    try:
        ws = ws_mod.resolve_workspace(workspace)
        STATE.ws = ws
        STATE.cfg = load_config(ws.config_path)
    except WorkspaceError:
        pass

    common = dict(
        title="LitNexus",
        port=port,
        reload=False,
        storage_secret="litnexus-gui",
    )

    if native:
        try:
            ui.run(native=True, show=False, **common)
            return
        except Exception:  # noqa: BLE001 —— 原生窗口失败（多为缺 WebView 运行时）→ 回退浏览器
            logger.warning("原生窗口启动失败，回退浏览器模式打开。", exc_info=True)

    ui.run(native=False, show=show, **common)

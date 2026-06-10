"""Typer CLI 根 app。"""

from __future__ import annotations

import logging
import multiprocessing
import sys
from pathlib import Path
from typing import Annotated

import click
import typer

from litnexus.cli import (
    cmd_ask,
    cmd_db,
    cmd_download,
    cmd_export,
    cmd_import,
    cmd_merge,
    cmd_translate,
    ui,
)
from litnexus.cli.options import (
    DownloadMode,
    DownloadModeOption,
    WorkspaceOption,
    YesOption,
)

CONFIG_NEXT_STEP = "用 `litnexus init <目录>` 创建工作区，或用 --workspace 指定。"
API_KEY_NEXT_STEP = "设置 LITNEXUS_API_KEY，或在 litnexus.toml 的 [ai].api_key 中填写密钥。"

app = typer.Typer(
    name="litnexus",
    help="文献发现流水线：EPMC 下载 → SQLite → AI 分析",
    add_completion=False,
    pretty_exceptions_enable=False,
    pretty_exceptions_show_locals=False,
)

# 注册子命令
app.command("download")(cmd_download.download)
app.command("merge")(cmd_merge.merge)
app.command("translate")(cmd_translate.translate)
app.command("classify")(cmd_ask.ask)
app.command("ask", hidden=True)(cmd_ask.ask)
app.command("export")(cmd_export.export)
app.command("import")(cmd_import.import_csv)

# db 子组
db_app = typer.Typer(help="数据库管理命令", no_args_is_help=True)
db_app.command("stats")(cmd_db.stats)
db_app.command("migrate")(cmd_db.migrate)
db_app.command("backup")(cmd_db.backup)
db_app.command("reset-classification")(cmd_db.reset_classification)
app.add_typer(db_app, name="db")


def setup_logging(verbose: bool = False) -> None:
    """初始化日志配置，统一控制所有模块的输出级别和格式。"""
    level = logging.DEBUG if verbose else logging.WARNING
    logging.basicConfig(level=level, format="%(message)s", stream=sys.stderr, force=True)
    # 抑制第三方库的噪声日志
    for noisy in ("httpx", "openai", "urllib3", "requests"):
        logging.getLogger(noisy).setLevel(logging.WARNING)


@app.callback(invoke_without_command=True)
def callback(
    ctx: typer.Context,
    verbose: Annotated[bool, typer.Option("--verbose", "-v", help="显示调试日志")] = False,
    plain: Annotated[bool, typer.Option("--plain", help="输出纯文本，适合日志和 CI")] = False,
    no_color: Annotated[bool, typer.Option("--no-color", help="禁用颜色，保留表格结构")] = False,
) -> None:
    ui.configure_ui(plain=plain, no_color=no_color)
    setup_logging(verbose)
    if ctx.invoked_subcommand is None:
        # 无子命令时默认打开图形界面（双击二进制即进 GUI）；命令列表用 --help 查看。
        # 装了 pywebview（desktop extra / 打包版）则用原生窗口，否则开浏览器。
        import importlib.util

        from litnexus.gui import launch

        native = importlib.util.find_spec("webview") is not None
        launch(None, native=native)
        raise typer.Exit()


@app.command("init")
def init(
    path: Annotated[Path, typer.Argument(help="工作区目录（默认当前目录）")] = Path("."),
    force: Annotated[bool, typer.Option("--force", help="覆盖已存在的模板文件")] = False,
):
    """初始化一个工作区：生成配置、检索列表模板和数据目录，并设为当前工作区。"""
    from litnexus.core.workspace import create_workspace

    try:
        ws = create_workspace(path, force=force)
    except OSError as e:
        ui.error("工作区无法创建", detail=str(e), next_step="检查目录权限，或换一个可写目录。")
        raise typer.Exit(1)

    ui.success(f"工作区已就绪：{ws.root}")
    ui.key_values(
        "下一步",
        [
            ("配置文件", ws.config_path),
            ("期刊列表", ws.journals_file),
            ("关键词列表", ws.root / "keywords.txt"),
            ("建议", "运行 `litnexus gui` 可视化配置并执行，或编辑后直接 `litnexus run`。"),
        ],
    )
    return ui.result("init", "ok", workspace=ws.root, config=ws.config_path)


@app.command("gui")
def gui(
    workspace: WorkspaceOption = None,
    native: Annotated[
        bool, typer.Option("--native", help="用原生桌面窗口（需安装 pywebview）")
    ] = False,
    port: Annotated[int, typer.Option("--port", help="本地端口")] = 8080,
):
    """打开图形配置面板（配置 + 跑流水线 + 导出/导入 CSV）。"""
    if native:
        import importlib.util

        if importlib.util.find_spec("webview") is None:
            ui.error(
                "缺少原生窗口依赖",
                detail="`--native` 需要 pywebview，但未安装。",
                next_step="运行 `uv sync --extra desktop` 安装，或去掉 --native 用浏览器打开。",
            )
            raise typer.Exit(1)

    from litnexus.gui import launch

    launch(workspace, native=native, port=port)


@app.command("run")
def run(
    from_step: Annotated[
        int, typer.Option("--from-step", min=1, max=5, help="从第几步开始（1-5）")
    ] = 1,
    to_step: Annotated[
        int, typer.Option("--to-step", min=1, max=5, help="到第几步结束（1-5）")
    ] = 5,
    skip_steps: Annotated[
        str | None, typer.Option("--skip", help="跳过步骤，逗号分隔，如 '3,4'")
    ] = None,
    mode: DownloadModeOption = DownloadMode.all,
    days: Annotated[int | None, typer.Option(help="下载最近 N 天")] = None,
    workspace: WorkspaceOption = None,
    yes: YesOption = False,
):
    """一键执行完整流水线（download→merge→translate→classify→export）。"""
    from litnexus.cli import context as ctx
    from litnexus.core.config import ConfigError, get_api_key
    from litnexus.core.workspace import WorkspaceError

    skip = set()
    if skip_steps:
        for s in skip_steps.split(","):
            try:
                step = int(s.strip())
            except ValueError:
                ui.error(
                    "跳过步骤格式无效",
                    detail=f"无法解析：{s}",
                    next_step="使用数字并用逗号分隔，例如 `--skip 3,4`。",
                )
                raise typer.Exit(1)
            if step < 1 or step > 5:
                ui.error(
                    "跳过步骤超出范围",
                    detail=f"step={step}",
                    next_step="步骤编号必须在 1 到 5 之间。",
                )
                raise typer.Exit(1)
            skip.add(step)

    if from_step > to_step:
        ui.error(
            "步骤范围无效",
            detail=f"from-step={from_step}, to-step={to_step}",
            next_step="确保 --from-step 小于或等于 --to-step。",
        )
        raise typer.Exit(1)

    try:
        _ws, cfg = ctx.load(workspace)
    except (WorkspaceError, ConfigError) as e:
        ui.error("无法加载工作区", detail=str(e), next_step=CONFIG_NEXT_STEP)
        raise typer.Exit(1)

    active_steps = set(range(from_step, to_step + 1)) - skip

    # ── 显示流水线总览 ─────────────────────────────────────────────────────
    step_names = {1: "download", 2: "merge", 3: "translate", 4: "classify", 5: "export"}
    ui.title("litnexus pipeline", "europe pmc → sqlite → ai → csv")
    ui.summary_table(
        "执行计划",
        ["步骤", "命令", "状态"],
        [
            (s, step_names[s], "跳过" if s in skip else "执行")
            for s in range(from_step, to_step + 1)
        ],
    )
    # ── 前置预检：在二次确认之前做，避免用户确认后才被告知缺配置 ──────────────
    needs_api = {3, 4} & active_steps
    if needs_api:
        try:
            get_api_key(cfg)
        except ConfigError as e:
            api_names = {3: "translate", 4: "classify"}
            names = "/".join(api_names[s] for s in sorted(needs_api))
            ui.error(
                "API Key 缺失",
                detail=f"步骤 {names} 需要 API Key。{e}",
                next_step=API_KEY_NEXT_STEP,
            )
            raise typer.Exit(1)

    if 4 in active_steps and not cfg.classify.questions:
        ui.error(
            "分类问题为空",
            detail="步骤 classify 需要 classify.questions。",
            next_step="在 litnexus.toml 中添加 [[classify.questions]]。",
        )
        raise typer.Exit(1)

    if not yes:
        ui.confirm("确认执行？")

    steps = {
        1: (
            "download",
            lambda: cmd_download.download(mode=mode, days=days, workspace=workspace, yes=True),
        ),
        2: ("merge", lambda: cmd_merge.merge(input_dir=None, workspace=workspace, yes=True)),
        3: (
            "translate",
            lambda: cmd_translate.translate(
                batch_size=None,
                concurrency=None,
                dry_run=False,
                workspace=workspace,
                yes=True,
            ),
        ),
        4: ("classify", lambda: cmd_ask.ask(workers=None, workspace=workspace, yes=True)),
        5: (
            "export",
            lambda: cmd_export.export(filter=None, output=None, workspace=workspace, yes=True),
        ),
    }

    results = []
    aborted_at: int | None = None
    for step_num in range(from_step, to_step + 1):
        name = steps[step_num][0]
        if step_num in skip:
            ui.warning(f"跳过步骤 {step_num}: {name}")
            results.append({"step": step_num, "command": name, "status": "skipped"})
            continue
        ui.title(f"步骤 {step_num}/{to_step}", name)
        try:
            step_result = steps[step_num][1]()
        except typer.Exit:
            # 子命令已自行打印错误详情
            results.append({"step": step_num, "command": name, "status": "failed"})
            aborted_at = step_num
            break
        except Exception as e:  # noqa: BLE001 —— 单步异常隔离，不让整条流水线 traceback 退出
            results.append({"step": step_num, "command": name, "status": "error", "error": str(e)})
            ui.error(f"步骤 {step_num}（{name}）出错", detail=str(e))
            aborted_at = step_num
            break
        results.append({"step": step_num, **(step_result or {"status": "ok"})})

    if aborted_at is not None:
        ui.summary_table(
            "流水线汇总（已中止）",
            ["步骤", "命令", "状态"],
            [(r["step"], r.get("command", ""), r.get("status", "")) for r in results],
        )
        ui.error(
            f"流水线在步骤 {aborted_at}（{steps[aborted_at][0]}）中止，后续步骤未执行。",
            next_step=f"修复后可用 `litnexus run --from-step {aborted_at}` 从该步续跑。",
        )
        raise typer.Exit(1)

    ui.success("流水线执行完毕。")
    return ui.result(
        "run",
        "ok",
        from_step=from_step,
        to_step=to_step,
        skipped=sorted(skip),
        steps=results,
    )


def main():
    # PyInstaller 冻结环境下，nicegui 原生窗口（pywebview）靠 multiprocessing
    # 启动窗口进程；缺少 freeze_support() 会导致子进程重新执行主程序、无限自我复制。
    multiprocessing.freeze_support()
    try:
        app(standalone_mode=False)
        return 0
    except click.exceptions.Exit as e:
        return e.exit_code
    except click.ClickException as e:
        e.show(file=sys.stderr)
        return e.exit_code


if __name__ == "__main__":
    raise SystemExit(main())

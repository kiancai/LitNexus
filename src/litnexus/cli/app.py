"""Typer CLI 根 app。"""

from __future__ import annotations

from pathlib import Path
from typing import Annotated, Optional

import typer

from litnexus.cli import cmd_download, cmd_merge, cmd_translate, cmd_export, cmd_ask, cmd_db

app = typer.Typer(
    name="litnexus",
    help="文献发现流水线：EPMC 下载 → SQLite → AI 分析",
    no_args_is_help=True,
    pretty_exceptions_show_locals=False,
)

# 注册子命令
app.command("download")(cmd_download.download)
app.command("merge")(cmd_merge.merge)
app.command("translate")(cmd_translate.translate)
app.command("classify")(cmd_ask.ask)
app.command("export")(cmd_export.export)

# db 子组
db_app = typer.Typer(help="数据库管理命令", no_args_is_help=True)
db_app.command("stats")(cmd_db.stats)
db_app.command("migrate")(cmd_db.migrate)
db_app.command("backup")(cmd_db.backup)
app.add_typer(db_app, name="db")


@app.command("run")
def run(
    from_step: Annotated[int, typer.Option(min=1, max=5, help="从第几步开始（1-5）")] = 1,
    to_step: Annotated[int, typer.Option(min=1, max=5, help="到第几步结束（1-5）")] = 5,
    skip_steps: Annotated[Optional[str], typer.Option(help="跳过步骤，逗号分隔，如 '3,4'")] = None,
    mode: Annotated[str, typer.Option(help="下载模式：journals|keywords|all")] = "all",
    days: Annotated[Optional[int], typer.Option(help="下载最近 N 天")] = None,
    config: Annotated[Optional[Path], typer.Option(help="config.toml 路径")] = None,
):
    """一键执行完整流水线（download→merge→translate→classify→export）。"""
    from litnexus.core.config import load_config, ConfigError

    skip = set()
    if skip_steps:
        for s in skip_steps.split(","):
            try:
                skip.add(int(s.strip()))
            except ValueError:
                pass

    try:
        load_config(config)  # 提前验证配置
    except ConfigError as e:
        typer.echo(f"配置错误：{e}", err=True)
        raise typer.Exit(1)

    steps = {
        1: ("download",  lambda: cmd_download.download(mode=mode, days=days, config=config)),
        2: ("merge",     lambda: cmd_merge.merge(input_dir=None, config=config)),
        3: ("translate", lambda: cmd_translate.translate(batch_size=None, concurrency=None, dry_run=False, config=config)),
        4: ("classify",  lambda: cmd_ask.ask(workers=None, config=config)),
        5: ("export",    lambda: cmd_export.export(filter=None, output=None, config=config)),
    }

    for step_num in range(from_step, to_step + 1):
        if step_num in skip:
            typer.echo(f"[跳过] 步骤 {step_num}: {steps[step_num][0]}")
            continue
        typer.echo(f"\n{'='*50}")
        typer.echo(f"步骤 {step_num}/5: {steps[step_num][0]}")
        typer.echo("=" * 50)
        steps[step_num][1]()

    typer.echo("\n流水线执行完毕。")


@app.command("init-config")
def init_config(
    force: Annotated[bool, typer.Option("--force", help="覆盖已有配置文件")] = False,
):
    """在 ~/.config/litnexus/ 生成默认配置文件和列表模板。"""
    from litnexus.core.config import (
        DEFAULT_CONFIG_DIR, DEFAULT_CONFIG_PATH,
        DEFAULT_CONFIG_TOML, DEFAULT_JOURNALS_TXT, DEFAULT_KEYWORDS_TXT,
    )

    DEFAULT_CONFIG_DIR.mkdir(parents=True, exist_ok=True)

    files = {
        DEFAULT_CONFIG_PATH: DEFAULT_CONFIG_TOML,
        DEFAULT_CONFIG_DIR / "journals.txt": DEFAULT_JOURNALS_TXT,
        DEFAULT_CONFIG_DIR / "keywords_1.txt": DEFAULT_KEYWORDS_TXT,
    }

    for path, content in files.items():
        if path.exists() and not force:
            typer.echo(f"  已存在（跳过）：{path}")
        else:
            path.write_text(content, encoding="utf-8")
            typer.echo(f"  已生成：{path}")

    typer.echo(f"\n请编辑 {DEFAULT_CONFIG_PATH} 填入数据库路径和 API key。")


def main():
    app()


if __name__ == "__main__":
    main()

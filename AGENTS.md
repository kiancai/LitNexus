# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## 项目概述

LitNexus 是一个文献发现与筛选流水线：通过 Europe PMC API 抓取期刊/关键词相关文章，存入 SQLite 数据库去重管理，借助 AI API 批量翻译标题、做多问题分类初筛，导出 CSV 供人工复筛后再导回数据库。

所有用户数据集中在一个「工作区」目录（类似 Obsidian vault），便于备份、同步与跨机迁移。

## ⚠️ 架构转向：原生重写（进行中，2026-06）

项目正在从 **Python/NiceGUI** 转向 **每平台各自的原生应用**，目标是 **轻量（十几 MB 级而非几百 MB）+ 优雅 + 双击即开、不依赖任何额外运行时**。决策依据：NiceGUI 是 Web 框架，Windows 上需 WebView2 运行时（Win10 常缺），且打包后体积大。

- **逻辑策略 = 方案 A（各自重写）**：Mac 用 Swift、Windows 用 C# 各写一份逻辑，不做共享引擎（逻辑简单、有测试当标尺，跑偏风险低，换最小体积与最纯原生）。
- **Linux**：暂不做（用户同意可砍，Mac + Windows 为必须）。
- **`src/litnexus`（Python）= 参考实现 / 行为规范**：原生版照它的逻辑与 `tests/` 的 35 个用例 1:1 移植，确保行为不变。Python CLI/GUI 暂留作对照，等原生版稳定后再决定退役。

### Mac 版（`mac/`，进行中）

SwiftUI，系统 AppKit 渲染、零捆绑运行时、`.app` 约 2MB。**不需要 Xcode**——本机 Command Line Tools 自带的 Swift 编译器 + SPM 即可编译。

- **引擎已完成并验证**：`Sources/LitNexus/Engine/` 1:1 移植 Python core（配置 TOML/工作区/SQLite schema v2+动态列/EPMC/翻译/分类/CSV）。`swift run LitNexus selftest` 跑 38 项断言；`epmctest` 实时联网验证 EPMC；`aitest` 验证 AI（读 LNX_BASE/LNX_KEY/LNX_MODEL 环境变量）。
- **界面已基本完整、仍在按反馈迭代（尚未定型）**：`Sources/LitNexus/UI/`。项目选择 → 首次向导 → 侧边栏 + 运行(步骤化状态卡+进度条+预计时间)/数据/配置。配色石墨黑+靓蓝。
- 已定的几个关键设计：AI 用**多方案模型**（添加/选择/删除/编辑即时持久化）；设置**自动保存**（无底部保存按钮，离开页面即存）；**不读任何环境变量**（桌面端以界面所选方案为准）；合并**只处理新文件**（已合并移入 `downloads/_merged/`）。

```bash
cd mac && swift build              # 编译验证
cd mac && swift run LitNexus selftest   # 引擎自检（38 项）
cd mac && ./make_app.sh release    # 产出可双击的 LitNexus.app
```

### Windows 版（`windows/`，已规划，**暂缓未做**）

> **为何暂缓**：Mac 版的功能与形态仍在按用户反馈快速迭代、尚未定型。等 Mac 版稳定后，再以它为蓝本一次性复刻到 Windows，避免两端同时改、反复返工。

计划做法（届时执行）：
- **技术栈**：C# + **WPF，目标 .NET Framework 4.8**（所有 Win10/11 预装 → exe 仅几 MB、用户无需装任何运行时；这正是放弃 NiceGUI/WebView2 的核心理由）。
- **逻辑**：照 `mac/` 的 Swift 引擎 + Python 参考，用 C# 重写一份（方案 A），并移植 selftest 的断言作为验收。
- **界面**：复刻 Mac 版定型后的动线与配色（侧边栏 + 三页 + 向导 + 步骤化运行 + AI 多方案 + 自动保存）。
- **构建/测试环境**：SSH 主机 `desktop-kian-tailscale`（Win10）。**已装好 .NET 8 SDK**（用官方 `dotnet-install.ps1` 装到用户目录 `~/.dotnet`，免管理员；winget 在 SSH 会话下取源会失败，勿用）。在真机上 `dotnet build` + 运行，不靠 CI 盲打。
- **打包**：onedir/自包含按需，最终发布产物为双击即用的 exe，不依赖外部运行时。

---

以下为 **Python 参考实现** 的说明（仍是当前行为规范）：

## 安装与开发

```bash
# 开发模式安装（需要 uv）
uv sync                     # 含 GUI 依赖（nicegui）
uv sync --extra dev         # 额外装 pytest / ruff / pyinstaller

# 运行 CLI / GUI
uv run litnexus --help
uv run litnexus gui

# 测试与 lint
uv run pytest
uv run ruff check src/

# 全局安装（从 GitHub）
uv tool install git+https://github.com/kiancai/LitNexus
```

## 工作区模型

LitNexus 不使用全局 `~/.config` 路径，而是把全部用户数据放进一个自包含的「工作区」目录：

```
<root>/
├── litnexus.toml   配置（GUI 表单读写，也可手动编辑）
├── journals.txt    期刊列表
├── keywords.txt    关键词检索式列表（也支持 keywords/*.txt 多文件）
├── litnexus.db     SQLite 数据库（WAL 模式）
├── downloads/      下载的原始 JSONL
└── exports/        导出的 CSV
```

工作区解析优先级（`core/workspace.py:resolve_workspace`）：
`--workspace/-w 参数` > `LITNEXUS_WORKSPACE` 环境变量 > 活动工作区指针。

唯一存在工作区之外的状态，是 OS 标准配置目录（platformdirs）下的 `state.toml`，记录「当前活动工作区」与「最近打开列表」。

## CLI 使用

```bash
litnexus init <目录>        # 创建工作区（写配置/列表模板/数据目录）并设为活动工作区
litnexus gui                # 打开图形面板（配置 + 跑流水线 + 导入/导出 CSV）
litnexus                    # 不带子命令 = 打开图形面板（装有 pywebview 时用原生窗口，否则浏览器）

# 完整流水线（5 步）
litnexus download           # 从 Europe PMC 下载 JSONL → downloads/
litnexus merge              # 合并 JSONL 入 SQLite（自动去重）
litnexus translate          # 批量翻译标题（batch=30）
litnexus classify           # AI 多问题分类（结果直接写入数据库；旧名 ask 仍作隐藏别名）
litnexus export             # 导出文章到 CSV → exports/
litnexus import <csv>       # 把人工编辑过的复筛 CSV 标注回写数据库（独立命令，不在 run 内）

litnexus run                # 一键执行 download→merge→translate→classify→export
litnexus run --from-step 3  # 从第 3 步开始（1-5）
litnexus run --to-step 2    # 到第 2 步结束
litnexus run --skip 3,4     # 跳过指定步骤
litnexus run --mode journals|keywords|all --days N

litnexus db stats           # 显示数据库统计（含各问题 是/否/失败 细分）
litnexus db migrate         # 手动确认 schema 迁移 / 动态列（报告版本与列数）
litnexus db backup          # 备份数据库为 .db.bak
litnexus db reset-classification [--failed|--all]  # 把分类结果置回 NULL 以便重跑
```

全局开关（放在子命令前）：`-v/--verbose`、`--plain`（纯文本，适合 CI）、`--no-color`。
各写操作命令默认执行前二次确认，`-y/--yes` 跳过。多数命令支持 `-w/--workspace` 指定工作区。

## 配置

配置文件位于**工作区根目录**的 `litnexus.toml`（由 `litnexus init` 生成，也可用 GUI 编辑）。参考 `config.example.toml`。

- **API key 优先级**：`LITNEXUS_API_KEY` > `ARK_API_KEY` > `litnexus.toml [ai].api_key`
- **Base URL 优先级**：`LITNEXUS_BASE_URL` > `ARK_API_BASE_URL` > `litnexus.toml [ai].base_url`

## 代码结构

```
src/litnexus/
├── cli/           # Typer CLI 命令层（薄壳，调用 core 模块）
│   ├── app.py     # 根 app + init / gui / run 命令 + main() 入口
│   ├── cmd_*.py   # 各子命令实现（download/merge/translate/ask/export/import/db）
│   ├── context.py # 解析工作区 + 加载配置的公共逻辑
│   ├── options.py # 复用的 Typer 选项类型（WorkspaceOption / YesOption / DownloadMode）
│   └── ui.py      # 基于 Rich 的终端输出与进度（--plain / --no-color 回退）
├── core/          # 业务逻辑层
│   ├── config.py        # 配置加载（TOML + Pydantic + env var 覆盖）
│   ├── config_saver.py  # 把 Config 回写为 TOML（供 GUI 保存）
│   ├── workspace.py     # 工作区（vault）定位与创建
│   ├── db.py            # 数据库操作 + 自动 schema 迁移 + 动态列管理
│   ├── epmc.py          # Europe PMC API 客户端（分页 + 重试）
│   ├── translator.py    # 批量翻译（AsyncOpenAI）
│   ├── classifier.py    # AI 分类（ThreadPoolExecutor，直接读写 DB）
│   └── io.py            # JSONL 读写、EPMC→schema 映射、CSV 导出/导回
└── gui/
    └── app.py     # NiceGUI 桌面应用（左侧边栏 + 运行/数据/配置 三个独立子页 + 首次设置向导）
```

## 数据流

```
Europe PMC API
    ↓ litnexus download → <ws>/downloads/*.jsonl
    ↓ litnexus merge    → <ws>/litnexus.db（INSERT OR IGNORE 去重）
    ↓ litnexus translate → db.title_zh（只翻译标题，批量 API 调用）
    ↓ litnexus classify → db.{qid}_ans / {qid}_rea（直接写入数据库）
    ↓ litnexus export   → <ws>/exports/articles_TIMESTAMP.csv
    ← litnexus import   ← 人工编辑过的 CSV 回写 include/tags 等标注列
```

## 数据库 Schema（v2，基础 16 列 + 动态列）

固定的 16 个基础列 + 运行时按配置 `ALTER TABLE` 增补的两类动态列：问题列（`{qid}_ans` / `{qid}_rea`）、自定义注释列（默认 `include` / `tags`）。

| 列 | 说明 |
|---|---|
| `epmc_id` | 主键 |
| `pmid` / `doi` | UNIQUE 约束，去重用 |
| `source` | `MED`（正式发表）或 `PPR`（预印本）|
| `title` / `abstract` | 原文标题 / 摘要 |
| `title_zh` | AI 翻译标题（只翻译标题，不翻译摘要）|
| `{qid}_ans` / `{qid}_rea` | AI 分类的答案（`是`/`否`；无标题摘要时为 `N/A`）与理由。调用/解析失败的文章**不写库**（`_ans` 保持 NULL），下次运行自动重试 |
| `include` | 人工复筛标记（`yes`/`no`/NULL，小写）|
| `tags` | 人工自由标注 |

schema 版本由 `PRAGMA user_version` 跟踪，`get_connection()` 时自动检测并迁移（迁移前自动备份为 `.db.bak`）。动态列由 `ensure_dynamic_columns()` 在每次连接时按配置补齐。

## 修改 AI 分类逻辑

分类问题在 `litnexus.toml` 的 `[[classify.questions]]` 数组中配置，每项含：
- `id`：作为数据库列前缀（`{id}_ans` / `{id}_rea`）
- `text`：发给 AI 的问题 prompt

新增/修改问题无需改代码，下次 `classify` 时自动建对应列并处理。

## 发布

打 tag（`v*`）自动触发 GitHub Actions：
- `ci.yml` — ruff lint + pytest（push/PR 触发）
- `release.yml` — PyInstaller 只构建 3 平台 **GUI 窗口版**桌面应用（Linux x86_64 / macOS arm64 / Windows x86_64），双击即用、无终端窗口；不再打 CLI 控制台二进制（命令行用户用 `uv tool install`）。原生窗口依赖：Windows 需 WebView2 运行时、Linux 需 WebKitGTK；缺失时应用会自动回退浏览器模式。macOS Intel 已弃用。

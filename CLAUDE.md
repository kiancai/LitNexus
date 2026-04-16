# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

LitNexus 是一个文献发现与筛选流水线，通过 Europe PMC API 抓取期刊/关键词相关文章，存入 SQLite 数据库去重管理，并借助 AI API 批量翻译标题、做双问题分类初筛。

## 安装与开发

```bash
# 开发模式安装（需要 uv）
uv sync

# 运行 CLI
uv run litnexus --help

# 全局安装（从 GitHub）
uv tool install git+https://github.com/user/litnexus
```

## CLI 使用

```bash
litnexus init-config        # 生成 ~/.config/litnexus/config.toml 和列表模板

# 完整流水线（6步）
litnexus download           # 从 Europe PMC 下载 JSONL
litnexus merge              # 合并 JSONL 入 SQLite（自动去重）
litnexus translate          # 批量翻译标题（batch=30）
litnexus export             # 导出未审阅文章到 CSV
litnexus ask                # AI 双问题分类
litnexus sync               # 将分析结果回写数据库

litnexus run                # 一键执行以上全部步骤
litnexus run --from-step 3  # 从第3步开始
litnexus run --skip-steps 4,5  # 跳过步骤

litnexus db stats           # 显示数据库统计
litnexus db migrate         # 手动触发 schema 迁移
litnexus db backup          # 备份数据库
```

## 配置

配置文件位于 `~/.config/litnexus/config.toml`。参考 `config.example.toml`。

**API key 优先级**：`LITNEXUS_API_KEY` 环境变量 > `ARK_API_KEY` 环境变量 > config.toml `[ai].api_key`

关键词/期刊列表文件默认在 `~/.config/litnexus/journals.txt` 和 `keywords_1.txt`。

## 代码结构

```
src/litnexus/
├── cli/           # Typer CLI 命令层（薄壳，调用 core 模块）
│   ├── app.py     # 根 app + run/init-config 命令
│   └── cmd_*.py   # 各子命令实现
└── core/          # 业务逻辑层
    ├── config.py  # 配置加载（TOML + Pydantic + env var 覆盖）
    ├── db.py      # 数据库操作 + 自动 schema 迁移
    ├── epmc.py    # Europe PMC API 客户端
    ├── translator.py  # 批量翻译（AsyncOpenAI）
    ├── classifier.py  # AI 分类（ThreadPoolExecutor）
    └── io.py      # JSONL 读写、CSV 导出工具
```

## 数据流

```
Europe PMC API
    ↓ litnexus download → download/*.jsonl
    ↓ litnexus merge    → ~/.local/share/litnexus/epmc_articles.db
    ↓ litnexus translate → db.title_zh（只翻译标题，批量 API 调用）
    ↓ litnexus export   → export/articles_TIMESTAMP.csv
    ↓ litnexus ask      → export/articles_analyzed_TIMESTAMP.csv
    ↓ litnexus sync     → db.q1_ans/q2_ans/include/tags
```

## 数据库 Schema（v1，23列）

| 列 | 说明 |
|---|---|
| `epmc_id` | 主键 |
| `pmid` / `doi` | UNIQUE 约束，去重用 |
| `source` | `MED`（正式发表）或 `PPR`（预印本）|
| `title_zh` | AI 翻译标题（只翻译标题，不翻译摘要） |
| `include` | 人工复筛标记（`yes`/`no`/NULL，小写）|
| `q1_ans` / `q2_ans` | AI 分类结果（`是`/`否`）|

schema 版本由 `PRAGMA user_version` 跟踪，`get_connection()` 时自动迁移。

## 修改 AI 分类逻辑

分类问题 prompt 在 `config.toml` 的 `[classify].question_1` / `question_2` 中配置，无需修改代码。

## 发布

打 tag 自动触发 GitHub Actions：
- `ci.yml` — ruff lint + pytest
- `release.yml` — PyInstaller 构建 4 平台二进制并发布到 GitHub Release

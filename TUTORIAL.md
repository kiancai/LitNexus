# LitNexus 使用教程

LitNexus 是一个文献发现与筛选流水线，完成从 **Europe PMC 抓取** → **SQLite 去重存储** → **AI 翻译标题** → **AI 多问题分类** → **CSV 导出** → **人工复筛回写** 的全流程。提供 CLI 与图形界面两套入口。

---

## 目录

1. [安装](#1-安装)
2. [创建工作区](#2-创建工作区)
3. [配置文件详解](#3-配置文件详解)
4. [检索列表配置](#4-检索列表配置)
5. [完整流水线](#5-完整流水线)
6. [分步执行](#6-分步执行)
7. [人工复筛与回写](#7-人工复筛与回写)
8. [图形界面](#8-图形界面)
9. [中断与恢复](#9-中断与恢复)
10. [数据库管理](#10-数据库管理)
11. [常见问题](#11-常见问题)

---

## 1. 安装

### 前置要求

- macOS / Linux / Windows
- [uv](https://docs.astral.sh/uv/)（推荐）或 Python ≥ 3.11

### 安装 uv（如果还没有）

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
# 安装后重启终端，或：
source ~/.zshrc
```

### 克隆并安装项目

```bash
git clone https://github.com/your-username/LitNexus.git
cd LitNexus

# 建立虚拟环境并安装依赖（自动读取 pyproject.toml，含图形界面依赖）
uv sync

# 验证安装
uv run litnexus --help
```

> **与 conda 共存**：uv 创建的 `.venv/` 与 conda 环境完全隔离。即使 conda 某个环境处于激活状态，`uv run` 也不受影响，无需 `deactivate`。

---

## 2. 创建工作区

LitNexus 把所有用户数据集中在一个**工作区**目录里（类似 Obsidian 的 vault），便于备份、同步盘/git 同步和跨机迁移。

```bash
uv run litnexus init ~/LitNexus
```

这会在 `~/LitNexus` 下铺好：

```
~/LitNexus/
├── litnexus.toml   ← 主配置文件（需要编辑，或用 GUI 编辑）
├── journals.txt    ← 期刊列表
├── keywords.txt    ← 关键词检索式列表
├── litnexus.db     ← SQLite 数据库（首次 merge 时创建）
├── downloads/      ← 下载的原始 JSONL 文件
└── exports/        ← 导出的 CSV 文件
```

`init` 会把这个目录设为「当前活动工作区」，后续命令默认作用于它。

### 工作区如何被定位

每条命令解析工作区的优先级为：

1. `--workspace / -w` 参数（显式指定）
2. `LITNEXUS_WORKSPACE` 环境变量
3. 当前活动工作区（`init` 或上次 `--workspace` 记录的指针）

```bash
# 临时对另一个工作区操作
uv run litnexus db stats --workspace ~/Projects/microbiome-lit

# 用环境变量固定工作区
export LITNEXUS_WORKSPACE=~/Projects/microbiome-lit
```

> 「当前活动工作区/最近列表」记录在操作系统标准配置目录下的 `state.toml`（macOS `~/Library/Application Support/litnexus/`、Linux `~/.config/litnexus/`、Windows `%APPDATA%\litnexus\`）——这是唯一存在于工作区之外的状态。

---

## 3. 配置文件详解

编辑工作区里的 `litnexus.toml`（也可跳过这步，用 `litnexus gui` 图形编辑）：

```toml
[download]
days = 30           # 抓取最近 N 天内首次发表的文章
page_size = 1000    # 每页返回数量（建议保持 1000）
request_delay = 0.5 # 每页请求之间的间隔（秒），避免被限速

[ingest]
# 额外从 Europe PMC 抓取并入库的字段 id（可选）。可用 id：
#   cited_by_count, is_open_access, in_epmc, has_pdf, pub_type, mesh_terms, language, issn
extra_fields = []

[ai]
# API key 优先级：环境变量 LITNEXUS_API_KEY > ARK_API_KEY > 此处 api_key
# Base URL 优先级：环境变量 LITNEXUS_BASE_URL > ARK_API_BASE_URL > 此处 base_url
api_key = ""
base_url = "https://ark.cn-beijing.volces.com/api/v3"
model = "doubao-1-5-pro-32k-character-250715"

[translate]
batch_size = 30   # 每次 API 调用翻译多少个标题
concurrency = 20  # 并发请求数

[classify]
max_workers = 100 # 并发线程数

# 分类问题：id 作为数据库列前缀（{id}_ans / {id}_rea），text 是发给 AI 的 prompt
[[classify.questions]]
id = "q1"
text = "请判断本文是否属于计算生物学、生物信息学或生物医学领域……"

[[classify.questions]]
id = "q2"
text = "请判断本文是否属于以下核心领域……"

[schema]
# 人工复筛时填写的自定义注释列（TEXT 类型，连接数据库时自动建列）
custom_columns = ["include", "tags"]

[export]
filter = "pending"   # pending（未复筛）| all（全部）| 自定义 SQL WHERE 子句
exclude_columns = [  # 导出 CSV 时排除的列
    "journal_info_json",
    "keyword_list_json",
    "abstract_zh",
]
```

### API Key 配置方式（三选一）

推荐用环境变量，避免密钥写入文件：

```bash
# 方式 1：临时设置（当前终端会话有效）
export LITNEXUS_API_KEY="your-key-here"

# 方式 2：永久写入（加到 ~/.zshrc 或 ~/.bashrc）
echo 'export LITNEXUS_API_KEY="your-key-here"' >> ~/.zshrc
source ~/.zshrc

# 方式 3：直接写入 litnexus.toml 的 [ai].api_key（注意别提交到 git）
```

> 兼容火山方舟：也可用 `ARK_API_KEY` / `ARK_API_BASE_URL` 环境变量。

---

## 4. 检索列表配置

### 期刊列表（`journals.txt`）

每行一个期刊名，名称需与 Europe PMC 数据库中完全一致，`#` 开头为注释：

```
# 顶刊
Nature
Science
Cell

# 生物信息学期刊
Bioinformatics
Genome Biology
PLOS Computational Biology
Briefings in Bioinformatics
```

> 如何确认名称：在 [Europe PMC](https://europepmc.org/) 搜索框输入 `JOURNAL:"期刊名"` 测试是否有结果。

### 关键词检索式（`keywords.txt`）

支持 Europe PMC 的布尔表达式语法，每行一个检索式：

```
# 微生物组
(microbiome OR microbiota) AND "machine learning"
TITLE:(gut microbiome) AND ABSTRACT:(deep learning)

# 生物信息工具
"single cell" AND (tool OR pipeline OR software)

# 基础模型
(foundation model OR large language model) AND (protein OR genomics OR RNA)
```

**常用语法：**

| 语法 | 说明 |
|------|------|
| `TITLE:(...)` | 在标题中搜索 |
| `ABSTRACT:(...)` | 在摘要中搜索 |
| `AND` / `OR` / `NOT` | 布尔运算符（大写） |
| `"精确短语"` | 精确匹配短语 |

> **多文件组织**：除根目录的 `keywords.txt` 外，还可在工作区下建 `keywords/` 子目录，把检索式拆成多个 `.txt` 文件（如 `keywords/microbiome.txt`、`keywords/llm.txt`）。下载时会逐个文件处理，并以文件名区分产物。

---

## 5. 完整流水线

配置好后，一条命令执行全部 5 个步骤：

```bash
uv run litnexus run
```

流水线步骤：

```
步骤 1: download   → 从 Europe PMC 下载 JSONL 文件
步骤 2: merge      → 将 JSONL 合并入 SQLite（自动去重）
步骤 3: translate  → 批量 AI 翻译标题（每批 30 个）
步骤 4: classify   → AI 多问题分类（并发 100 线程）
步骤 5: export     → 导出文章到 CSV
```

> 复筛回写（`import`）是独立命令，**不在** `run` 流水线内——因为它需要你先在 Excel 里手动编辑导出的 CSV。

### 常用选项

```bash
# 只下载最近 7 天的文章
uv run litnexus run --days 7

# 只抓取期刊列表（跳过关键词）
uv run litnexus run --mode journals

# 只抓取关键词列表
uv run litnexus run --mode keywords

# 从第 3 步开始（已有数据，不需要重新下载）
uv run litnexus run --from-step 3

# 跳过第 1、2 步
uv run litnexus run --skip 1,2

# 只执行第 1-2 步（下载 + 入库，不调用 AI）
uv run litnexus run --to-step 2

# 跳过确认，无人值守运行
uv run litnexus run --yes

# 显示详细日志（调试用）
uv run litnexus --verbose run

# 纯文本输出（适合写入日志 / CI）
uv run litnexus --plain run --yes
```

> **前置预检**：`run` 会在调用 AI 的步骤前验证 API key 和分类问题是否就绪，缺失立即报错，不会等到第 3、4 步才失败。

---

## 6. 分步执行

也可以单独运行每个步骤，灵活控制流程。各命令都支持 `--workspace/-w` 指定工作区、`--yes/-y` 跳过确认。

### 步骤 1：下载

```bash
uv run litnexus download

# 指定天数和模式（journals / keywords / all）
uv run litnexus download --days 14 --mode keywords
```

每次下载生成带时间戳的新文件，不覆盖历史文件：

```
~/LitNexus/downloads/
├── epmc_journals_20260401_120000.jsonl
├── epmc_keywords_20260401_120000.jsonl
└── epmc_keywords_20260415_093000.jsonl   ← 新文件
```

> 注意：当前 download 每次都会把整个结果集重新抓一遍（没有增量），重复运行会在 `downloads/` 里累积重复文件——重复内容靠后续 merge 的去重兜底，必要时可手动清理旧 JSONL。

### 步骤 2：合并入库

```bash
uv run litnexus merge

# 从指定目录读取 JSONL
uv run litnexus merge --input-dir ./some/dir
```

读取工作区 `downloads/` 下所有 `.jsonl` 文件，通过 `epmc_id`（主键）、`pmid`、`doi`（UNIQUE）三重去重，插入 SQLite。重复文章自动跳过，不会覆盖已有数据。首次 merge 会自动创建数据库并建表。

### 步骤 3：翻译标题

```bash
uv run litnexus translate

# 预览待翻译数量，不实际调用 API
uv run litnexus translate --dry-run

# 覆盖配置中的批量大小和并发数
uv run litnexus translate --batch-size 50 --concurrency 30
```

只翻译 `title_zh` 为空的文章，已翻译的自动跳过。

### 步骤 4：AI 分类

```bash
uv run litnexus classify

# 覆盖并发线程数
uv run litnexus classify --workers 50
```

> 旧命令名 `ask` 仍作为隐藏别名保留，等价于 `classify`。

对任一 `{id}_ans` 为空的文章进行分类，每篇一次 API 调用同时回答所有问题。结果写入数据库：

| 列 | 说明 |
|----|------|
| `q1_ans` | 问题 1 的答案（`是` / `否`；缺标题摘要时为 `N/A`） |
| `q1_rea` | 问题 1 的理由（简短说明） |
| `q2_ans` | 问题 2 的答案 |
| `q2_rea` | 问题 2 的理由 |

- `是` / `否`：AI 判定结果。
- `N/A`：文章缺少标题和摘要，无法判断（终态，不再处理）。
- **调用 / 解析失败的文章不写入结果**（`_ans` 保持为空），下次运行 `classify` 会自动重新尝试。

> 历史遗留 / 重跑：旧版本会把失败写成 `API错误`（不会自动重试）。要清理这类残留、或改了 prompt 想整体重分类，用 `db reset-classification`（见[第 10 节](#10-数据库管理)），它会把对应 `_ans`/`_rea` 置回 NULL，下次 `classify` 自动重新处理。

### 步骤 5：导出 CSV

```bash
uv run litnexus export

# 导出全部文章（包括已复筛的）
uv run litnexus export --where all

# 导出自定义条件（直接作为 SQL WHERE）
uv run litnexus export --where "q1_ans='是' AND q2_ans='是'"

# 指定输出路径
uv run litnexus export --output ~/Desktop/results.csv
```

默认导出 `include IS NULL` 的未复筛文章（`[export].filter = "pending"`），文件名带时间戳存入工作区 `exports/`。导出时会排除 `[export].exclude_columns` 中的列。

---

## 7. 人工复筛与回写

整个流水线只做「初筛」（AI 分类）。最终复筛在 Excel/表格软件里完成，再回写数据库：

1. `litnexus export` 导出 CSV。
2. 在 Excel 打开，按 AI 分类结果（`q1_ans`/`q2_ans` 等）人工判断，在 **`include`** 列填 `yes` 或 `no`（也可在 `tags` 等自定义列写备注）。留空表示「还没看」。
3. 把编辑后的 CSV 导回：

```bash
uv run litnexus import ~/Desktop/results.csv
```

回写规则：

- 按 `epmc_id`（回退 `pmid` / `doi`）匹配文章。
- 只写回 `[schema].custom_columns` 里配置的标注列（默认 `include` / `tags`）。
- **留空的单元格会被跳过**，不会抹掉数据库里已有的标注——所以可以分多次、增量复筛。
- 绝不触碰原文字段或 AI 分类列。
- `include` 的值会统一转小写。

之后再 `litnexus export`（默认 `pending`）就只会导出尚未复筛（`include` 仍为空）的文章，形成闭环。

---

## 8. 图形界面

不想用命令行的话，可以用图形面板完成几乎所有操作：

```bash
uv run litnexus gui              # 在浏览器打开（默认 http://localhost:8080）
uv run litnexus gui --port 9000  # 换端口
uv run litnexus gui --native     # 原生桌面窗口（需 `uv sync --extra desktop` 装 pywebview）
```

界面自上而下分三段：

- **数据**：数据库统计卡片、导出 CSV、把编辑过的 CSV 拖拽导入回写。
- **运行**：选择下载模式/天数，分步或一键执行下载→合并→翻译→分类，实时日志。
- **配置**：编辑期刊/关键词、AI 接口（含「测试连接」）、分类问题、自定义列、额外字段、各项参数与导出筛选，保存即写回 `litnexus.toml`。

右上角可切换深色/浅色主题、切换或新建工作区。字段旁的 `?` 悬停有说明（文案来自可编辑的 `help.toml`）。

---

## 9. 中断与恢复

大部分步骤可安全地中断后重跑：

| 步骤 | 恢复机制 | 重跑是否安全 |
|------|----------|:---:|
| download | 重新运行生成新 JSONL 文件，merge 时去重 | ✅（会重复消耗 API） |
| merge | `INSERT OR IGNORE`，重复文章自动跳过 | ✅ |
| translate | 只处理 `title_zh IS NULL` 的文章，每 500 条写一次库；失败保持 NULL，下次自动重试 | ✅ |
| classify | 只处理 `{id}_ans IS NULL` 的文章，每 50 条写一次库；失败不写库、保持 NULL，下次自动重试 | ✅ |
| export | 每次生成新文件（时间戳命名），对数据库只读 | ✅ |

**典型恢复场景：**

```bash
# 场景：classify 运行到一半被 Ctrl+C 中断
# 已写入的分类结果已保存（每 50 条批量写库）
# 重新运行，自动跳过已分类的文章继续处理：
uv run litnexus classify

# 场景：想从第 3 步重新开始（数据已入库）
uv run litnexus run --from-step 3
```

> classify 的失败会自动重试：调用 / 解析失败的文章不写库（`_ans` 仍为空），下次运行会重新尝试，无需手动干预。仅 `N/A`（无标题摘要）是终态。若数据库里还残留旧版本写入的 `API错误` 值，参见[步骤 4](#步骤-4ai-分类) 末尾把它们置回 NULL。

---

## 10. 数据库管理

### 查看统计

```bash
uv run litnexus db stats
```

输出示例：

```
数据库
  路径   ~/LitNexus/litnexus.db
  大小   42.7 MB

统计
  总文章数        12483
  待翻译            0
  待分类 q1        234
  待分类 q2        234
  include=yes     1820
  include=no      9876
```

### 备份数据库

```bash
uv run litnexus db backup
# 生成 litnexus.db.bak（同名 .bak，会覆盖上一次备份）
```

### 手动触发迁移 / 同步动态列

```bash
uv run litnexus db migrate
```

通常不需要手动执行——每次连接数据库时都会自动检测 schema 版本并迁移、补齐动态列。命令会报告当前 schema 版本与列数。schema 迁移前会自动把整库备份为 `.db.bak`。

### 重新分类（清空已有分类结果）

```bash
# 仅清理旧版本遗留的 API错误 失败行（不影响已正常分类的 是/否）
uv run litnexus db reset-classification

# 清空全部分类结果，整体重跑（例如改了 [[classify.questions]] 的 prompt 之后）
uv run litnexus db reset-classification --all
```

把对应问题的 `{id}_ans` / `{id}_rea` 置回 NULL，下次 `litnexus classify` 会重新处理这些文章。`db stats` 里每个问题的「失败/N/A」一行能帮你看出有多少需要清理的行。

### 工作区即数据，直接拷走

整个工作区目录是自包含的，直接复制 `~/LitNexus/` 到另一台机器即可继续用（`litnexus.db` 是单文件 SQLite）。在新机器上用 `litnexus init <该目录>` 或 `--workspace` 指向它即可。

---

## 11. 常见问题

**Q：运行时提示"未找到 API key"**

确认环境变量已设置：
```bash
echo $LITNEXUS_API_KEY
# 如果为空，重新设置：
export LITNEXUS_API_KEY="your-key"
```
或在工作区 `litnexus.toml` 的 `[ai].api_key` 填写。

---

**Q：提示"未找到工作区 / 工作区未初始化"**

先创建工作区，或指定一个已存在的：
```bash
uv run litnexus init ~/LitNexus
# 或
uv run litnexus <命令> --workspace ~/LitNexus
```

---

**Q：下载时提示"期刊列表为空"**

检查工作区里的 `journals.txt` / `keywords.txt` 是否有非注释、非空行：
```bash
cat ~/LitNexus/journals.txt
```

---

**Q：翻译或分类失败率很高**

- 检查 API key 是否有效、余额是否充足。
- 尝试降低并发：`translate --concurrency 5` 或 `classify --workers 20`。
- 用 `--verbose` 查看详细错误。
- 分类失败的行会被标记为 `API错误` 且不自动重试，参见[第 9 节](#9-中断与恢复)的重试方法。

---

**Q：想修改分类问题**

直接编辑 `litnexus.toml` 的 `[[classify.questions]]`（或用 GUI），下次运行 `classify` 时生效。新问题 id 会自动添加对应数据库列（`{id}_ans`、`{id}_rea`）。

---

**Q：数据库体积过大**

运行 SQLite VACUUM 压缩空间：
```bash
uv run python -c "import sqlite3; c=sqlite3.connect('/Users/you/LitNexus/litnexus.db'); c.execute('VACUUM'); c.close(); print('完成')"
```

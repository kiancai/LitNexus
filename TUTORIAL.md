# LitNexus 使用教程

LitNexus 是一个文献发现与筛选流水线，完成从 **Europe PMC 抓取** → **SQLite 去重存储** → **AI 翻译标题** → **AI 双问题分类** → **CSV 导出** 的全流程自动化。

---

## 目录

1. [安装](#1-安装)
2. [初始化配置](#2-初始化配置)
3. [配置文件详解](#3-配置文件详解)
4. [检索列表配置](#4-检索列表配置)
5. [完整流水线](#5-完整流水线)
6. [分步执行](#6-分步执行)
7. [中断与恢复](#7-中断与恢复)
8. [数据库管理](#8-数据库管理)
9. [常见问题](#9-常见问题)

---

## 1. 安装

### 前置要求

- macOS / Linux
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

# 建立虚拟环境并安装依赖（自动读取 pyproject.toml）
uv sync --python 3.13

# 验证安装
uv run litnexus --help
```

> **与 conda 共存**：uv 创建的 `.venv/` 与 conda 环境完全隔离。即使 conda 某个环境处于激活状态，`uv run` 也不受影响，无需 `deactivate`。

---

## 2. 初始化配置

首次使用，运行以下命令在用户目录生成配置文件和列表模板：

```bash
uv run litnexus init-config
```

生成的文件：

```
~/.config/litnexus/
├── config.toml       ← 主配置文件（需要编辑）
├── journals.txt      ← 期刊列表
└── keywords_1.txt    ← 关键词检索式列表
```

数据默认存放在：

```
~/.local/share/litnexus/
├── epmc_articles.db  ← SQLite 数据库
├── download/         ← 下载的原始 JSONL 文件
└── export/           ← 导出的 CSV 文件
```

---

## 3. 配置文件详解

编辑 `~/.config/litnexus/config.toml`：

```toml
[paths]
# 数据库路径（自动创建）
db = "~/.local/share/litnexus/epmc_articles.db"
# 下载目录：存放原始 JSONL 文件
download_dir = "~/.local/share/litnexus/download"
# 导出目录：存放 CSV 文件
export_dir   = "~/.local/share/litnexus/export"
# 期刊列表文件
journals_file = "~/.config/litnexus/journals.txt"
# 关键词列表文件（可配置多个）
keywords_files = [
    "~/.config/litnexus/keywords_1.txt",
]

[download]
days         = 30     # 抓取最近 N 天内发表的文章
page_size    = 1000   # 每页返回数量（建议保持 1000）
request_delay = 0.5   # 每页请求之间的间隔（秒），避免被限速

[ai]
# API key 优先级：环境变量 LITNEXUS_API_KEY > ARK_API_KEY > 此处配置
api_key  = ""
base_url = "https://ark.cn-beijing.volces.com/api/v3"
model    = "doubao-1-5-pro-32k-character-250715"

[translate]
batch_size  = 30   # 每次 API 调用翻译多少个标题（越大越省 token，但解析风险稍高）
concurrency = 20   # 并发请求数

[classify]
max_workers = 100  # 并发线程数

# 分类问题：id 会作为数据库列名前缀（q1_ans, q1_rea）
[[classify.questions]]
id   = "q1"
text = "请判断本文是否属于计算生物学、生物信息学或生物医学领域……"

[[classify.questions]]
id   = "q2"
text = "请判断本文是否属于以下核心领域……"

[schema]
# 用户自定义列（TEXT 类型，自动添加到数据库）
custom_columns = ["include", "tags"]

[export]
filter = "pending"   # pending（未审阅）| all（全部）| 自定义 SQL WHERE 子句
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

# 方式 3：直接写入 config.toml（不推荐提交到 git）
# api_key = "your-key-here"
```

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

### 关键词检索式（`keywords_1.txt`）

支持 Europe PMC 的布尔表达式语法：

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

可以配置多个关键词文件，在 `config.toml` 中添加：

```toml
keywords_files = [
    "~/.config/litnexus/keywords_1.txt",
    "~/.config/litnexus/keywords_2.txt",
]
```

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
步骤 4: classify   → AI 双问题分类（并发 100 线程）
步骤 5: export     → 导出未审阅文章到 CSV
```

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
uv run litnexus run --skip-steps 1,2

# 只执行第 1-2 步（下载 + 入库，不调用 AI）
uv run litnexus run --to-step 2

# 显示详细日志（调试用）
uv run litnexus --verbose run
```

> **前置预检**：`run` 命令启动时会验证所有必要配置（API key、问题列表等），如有缺失立即报错，不会等到第 3、4 步才失败。

---

## 6. 分步执行

也可以单独运行每个步骤，灵活控制流程。

### 步骤 1：下载

```bash
uv run litnexus download

# 指定天数和模式
uv run litnexus download --days 14 --mode keywords
```

每次下载生成带时间戳的新文件，不覆盖历史文件：
```
~/.local/share/litnexus/download/
├── epmc_journals_20260401_120000.jsonl
├── epmc_keywords_1_20260401_120000.jsonl
└── epmc_keywords_1_20260415_093000.jsonl   ← 新文件
```

### 步骤 2：合并入库

```bash
uv run litnexus merge
```

读取 `download/` 目录下所有 `.jsonl` 文件，通过 `epmc_id`、`pmid`、`doi` 三重去重，插入 SQLite 数据库。重复文章自动跳过，不会覆盖已有数据。

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

对 `q1_ans`、`q2_ans` 为空的文章进行分类。分类结果写入数据库，字段：

| 列 | 说明 |
|----|------|
| `q1_ans` | 问题 1 的答案（`是` / `否` / `N/A` / `API错误`） |
| `q1_rea` | 问题 1 的理由（简短说明） |
| `q2_ans` | 问题 2 的答案 |
| `q2_rea` | 问题 2 的理由 |

### 步骤 5：导出 CSV

```bash
uv run litnexus export

# 导出全部文章（包括已审阅的）
uv run litnexus export --filter all

# 导出自定义条件
uv run litnexus export --filter "q1_ans='是' AND q2_ans='是'"

# 指定输出路径
uv run litnexus export --output ~/Desktop/results.csv
```

默认导出 `include IS NULL` 的未审阅文章，文件名带时间戳。

---

## 7. 中断与恢复

每个步骤都是**幂等**的——中断后重新运行，自动从断点继续，不会重复处理已完成的数据。

| 步骤 | 恢复机制 |
|------|----------|
| download | 重新运行生成新 JSONL 文件，merge 时去重 |
| merge | `INSERT OR IGNORE`，重复文章自动跳过 |
| translate | 只处理 `title_zh IS NULL` 的文章 |
| classify | 只处理 `q*_ans IS NULL` 的文章，每 50 条写一次库 |
| export | 每次生成新文件（时间戳命名），不影响数据库 |

**典型恢复场景：**

```bash
# 场景：classify 运行到一半被 Ctrl+C 中断
# 已写入的分类结果已保存（每 50 条批量写库）
# 重新运行，自动跳过已分类的文章继续处理：
uv run litnexus classify

# 场景：想从第 3 步重新开始（数据已入库）
uv run litnexus run --from-step 3
```

---

## 8. 数据库管理

### 查看统计

```bash
uv run litnexus db stats
```

输出示例：
```
数据库：~/.local/share/litnexus/epmc_articles.db
  总文章数：              12483
  待翻译（无 title_zh）：  0
  待分类（q1_ans 为空）：  234
  待分类（q2_ans 为空）：  234
  已标记 include=yes：    1820
  已标记 include=no：     9876
```

### 备份数据库

```bash
uv run litnexus db backup
# 生成 epmc_articles.db.bak
```

### 手动触发迁移

```bash
uv run litnexus db migrate
```

通常不需要手动执行——每次 `get_connection()` 时自动检测并迁移。

### 人工审阅标记

导出的 CSV 中有 `include` 列，人工复审后在 CSV 中填写 `yes` 或 `no`，再通过 `sync` 命令回写数据库（如果配置了该步骤）。

---

## 9. 常见问题

**Q：运行时提示"未找到 API key"**

确认环境变量已设置：
```bash
echo $LITNEXUS_API_KEY
# 如果为空，重新设置：
export LITNEXUS_API_KEY="your-key"
```

---

**Q：下载时提示"期刊列表为空"**

检查 `journals.txt` 路径是否正确：
```bash
cat ~/.config/litnexus/journals.txt
```
确保文件中有非注释行。

---

**Q：翻译或分类失败率很高**

- 检查 API key 是否有效、余额是否充足
- 尝试降低并发数：`--concurrency 5` 或 `--workers 20`
- 用 `--verbose` 查看详细错误信息

---

**Q：想修改分类问题**

直接编辑 `config.toml` 中的 `[[classify.questions]]` 内容，下次运行 `classify` 时生效。新问题 id 会自动添加对应数据库列（`{id}_ans`、`{id}_rea`）。

---

**Q：数据库体积过大**

运行 SQLite VACUUM 压缩空间：
```bash
uv run python -c "
import sqlite3
conn = sqlite3.connect('~/.local/share/litnexus/epmc_articles.db')
conn.execute('VACUUM')
conn.close()
print('完成')
"
```

---

**Q：想在多台机器间同步数据库**

直接复制 `epmc_articles.db` 文件即可，SQLite 是单文件数据库。在新机器上同样路径放好后，正常运行 `uv run litnexus db migrate` 确认 schema 版本一致。

## LitNexus

- 基于生物交叉 ai 以后，大量重要文章会预先发表在 bioRxiv 乃至于 arXiv 上，但 pubmed 只会收录部分由 NIH 资助研究的预印本文章。想要紧跟前沿研究，仅凭 pubmed/wos 是不够的，但 google scholar 又不支持 api 调用。这是主要冲突。

- 鉴上，建议使用 Europe PMC，它在集成了 PubMed 的基础上，会进一步集成 bioRxiv、medRxiv，并提供了成熟的 api 调用。

- 简单的思路是，利用 Europe PMC 调用 api，通过检索自己关注的期刊与自己关注的关键词，即可基本覆盖关注领域。使用 sqlite 去重的管理下载的文献信息，并接入 ai api 对文章标题摘要进行初步判断，最后人工对初筛后文章进行快速复筛，找到前沿、关注的文章。

- 算是一种全覆盖式且较为快速的方法了。ai 复筛的 prompt 写的足够好可以很大程度减少筛选工作量。

详细使用见 [TUTORIAL.md](TUTORIAL.md)。

### 数据都在「工作区」里

所有用户数据集中在一个自包含的工作区目录（类似 Obsidian vault），便于备份与跨机迁移：

```
<工作区>/
├── litnexus.toml   配置
├── journals.txt    期刊列表
├── keywords.txt    关键词检索式（也支持 keywords/*.txt 多文件）
├── litnexus.db     SQLite 数据库
├── downloads/      下载的原始 JSONL
└── exports/        导出的 CSV
```

### 快速上手

```bash
# 安装（需要 uv）
uv sync

# 创建工作区并设为当前工作区
uv run litnexus init ~/LitNexus

# 编辑 ~/LitNexus 下的 journals.txt / keywords.txt，并设置 API key：
export LITNEXUS_API_KEY="your-key"

# 一键跑完整流水线：download → merge → translate → classify → export
uv run litnexus run
```

### 图形界面

```bash
uv run litnexus gui            # 浏览器打开配置面板（配置 + 跑流水线 + 导入/导出 CSV）
uv run litnexus gui --native   # 原生桌面窗口（需 `uv sync --extra desktop` 安装 pywebview）
```

### CLI 命令

```bash
uv run litnexus --help
```

| 命令 | 作用 |
|------|------|
| `init <目录>` | 创建工作区 |
| `download` | 从 Europe PMC 下载到 `downloads/` |
| `merge` | 合并 JSONL 入 SQLite（自动去重） |
| `translate` | 批量翻译标题 |
| `classify` | AI 多问题分类（结果写入数据库） |
| `export` | 导出 CSV 到 `exports/` |
| `import <csv>` | 把人工编辑过的复筛 CSV 回写数据库 |
| `run` | 一键执行 download→merge→translate→classify→export |
| `db stats / migrate / backup` | 数据库统计 / 迁移 / 备份 |

全局开关：`-v/--verbose`、`--plain`（纯文本，适合 CI/日志）、`--no-color`。
写操作默认二次确认，加 `-y/--yes` 跳过。

# 工作区与配置

## 工作区目录结构

```text
<root>/
├── litnexus.toml    # 配置（GUI / 手写）
├── journals.txt     # 期刊列表
├── keywords.txt     # 关键词检索式（也支持 keywords/*.txt）
├── litnexus.db      # SQLite（WAL）
├── downloads/       # 原始 JSONL（含 _merged/）
└── exports/         # 导出的 CSV
```

这是用户的「vault」：备份这个目录 ≈ 备份项目状态。

## 工作区如何被找到

解析优先级（Python 参考：`resolve_workspace`）：

1. CLI `--workspace` / `-w`
2. 环境变量 `LITNEXUS_WORKSPACE`
3. OS 标准配置目录下的 `state.toml` 中的**活动工作区**指针

工作区之外唯一的全局状态：`state.toml`（当前活动工作区 + 最近打开列表）。

Mac 桌面端：项目选择 / 向导创建工作区，路径写入本地状态；交互以 UI 为准。

## 配置文件

- 主文件：工作区根目录 `litnexus.toml`
- 仓库内示例：`config.example.toml`
- 分类问题：`[[classify.questions]]`，每项 `id` + `text`；增删问题后下次 classify 自动补列

### API 相关（Python / CLI 参考优先级）

| 项 | 优先级（高 → 低） |
|----|-------------------|
| API key | `LITNEXUS_API_KEY` > `ARK_API_KEY` > `litnexus.toml [ai].api_key` |
| Base URL | `LITNEXUS_BASE_URL` > `ARK_API_BASE_URL` > `litnexus.toml [ai].base_url` |

**Mac 桌面端**：AI **多方案**（添加 / 选择 / 删除 / 编辑即时持久化），**不读环境变量**。

## 列表文件

- `journals.txt`：期刊名（检索期刊通道）
- `keywords.txt` 或 `keywords/*.txt`：检索式（关键词通道）
- 空行与注释约定以实现/教程为准，使用文档中补全

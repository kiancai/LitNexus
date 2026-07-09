# 流水线与数据流

## 总览

```text
Europe PMC API
    ↓  download   →  <工作区>/downloads/*.jsonl
    ↓  merge      →  litnexus.db（INSERT OR IGNORE 去重）
    ↓  translate  →  db.title_zh（只译标题）
    ↓  classify   →  db.{qid}_ans / {qid}_rea
    ↓  export     →  exports/articles_TIMESTAMP.csv
    ←  import     ←  人工编辑后的 CSV（include / tags 等）
```

`run` 一键执行前五步；**`import` 独立**，不在默认 `run` 内。

## 各步职责

| 步骤 | 输入 | 输出 | 备注 |
|------|------|------|------|
| **download** | 期刊/关键词列表、天数等 | `downloads/*.jsonl` | 模式：journals / keywords / all |
| **merge** | 未合并的 JSONL | SQLite 行 | 去重；已合并文件进 `_merged/`（Mac 已定行为） |
| **translate** | 缺 `title_zh` 的行 | 更新 `title_zh` | 批量调用 AI |
| **classify** | 配置中的问题列表 | `{id}_ans` / `{id}_rea` | 失败不写库，下次可重试 |
| **export** | DB | CSV | 供人工复筛 |
| **import** | 编辑后的 CSV | 回写标注列 | 闭环 |

## 分类语义（要点）

- 问题在配置 `[[classify.questions]]` 中定义：`id` + `text`。
- 答案约定：`是` / `否`；无标题摘要时可为 `N/A`。
- **调用或解析失败**：不写 `_ans`（保持 NULL），下次运行自动重试。
- 旧 CLI 名 `ask` 可作为 classify 的隐藏别名（参考实现）。

## 可中断与重跑

流水线按步设计，支持从某步开始、跳到某步、跳过指定步（CLI `run` 的 from/to/skip）。翻译与分类均面向「尚未完成」的行，便于中断后继续。

更细的 CLI 参数与 GUI 对应关系，在使用文档中随实现补全。

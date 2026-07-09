# 数据库

## 概要

- 文件：工作区根目录 `litnexus.db`
- 模式：SQLite，WAL
- Schema 版本：`PRAGMA user_version`；连接时自动迁移（迁移前备份 `.db.bak`）
- 动态列：按配置 `ALTER TABLE` 补齐问题列与注释列

## 基础列（schema v2 思路）

固定基础列 + 运行时动态列。核心字段包括：

| 列 | 说明 |
|----|------|
| `epmc_id` | 主键 |
| `pmid` / `doi` | UNIQUE，去重 |
| `source` | `MED`（正式发表）或 `PPR`（预印本） |
| `title` / `abstract` | 原文 |
| `title_zh` | AI 翻译标题（不译摘要） |
| `{qid}_ans` / `{qid}_rea` | 分类答案与理由 |
| `include` | 人工复筛（`yes` / `no` / NULL，小写） |
| `tags` | 人工自由标注 |

动态列两类：

1. **问题列**：每个 classify 问题的 `_ans` / `_rea`
2. **注释列**：默认 `include` / `tags` 等

## 去重

合并阶段对主键/唯一约束使用 **INSERT OR IGNORE** 类语义，避免重复入库。

## 运维（参考 CLI）

| 能力 | 说明 |
|------|------|
| stats | 库统计（含各问题 是/否/失败等） |
| migrate | 确认 schema / 动态列 |
| backup | 备份为 `.db.bak` |
| reset-classification | 清空分类结果以便重跑（失败项或全部） |

字段级精确定义以代码与 selftest 为准；本文档描述**意图与不变量**，实现细节变更时同步改这里。

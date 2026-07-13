# LitNexus

**文献发现与筛选流水线**：Europe PMC 抓取 → 本地工作区 → AI 初筛 → CSV 人工复筛回写。

---

## 当前阶段

| 阶段 | 状态 |
|------|------|
| 文档站与架构 | 进行中 |
| Mac 原生收尾 | 文档定型后 |
| Windows 原生 | `win/` 已接入项目选择、基础配置和安全 CSV 复筛闭环；其余页面按 Mac 定型逐步复刻 |

> 节奏：**先文档 → Mac 收尾 → Windows**。

---

## 文档怎么读

| 你想了解… | 去看 |
|-----------|------|
| 为什么做 | [产品概述](product/overview.md) |
| 做什么 / 不做什么 | [目标与边界](product/scope.md) |
| 系统怎么拆 | [架构总览](architecture/overview.md) |
| 五步流水线 | [流水线](architecture/pipeline.md) |
| 工作区 / 库表 | [工作区](architecture/workspace.md) · [数据库](architecture/database.md) |
| mac / win | [多端策略](architecture/platforms.md) |
| 怎么跑 | [快速开始](guide/quickstart.md) |
| 接下来做什么 | [路线图](roadmap.md) |

---

## 源码与预览

- 仓库：[github.com/kiancai/LitNexus](https://github.com/kiancai/LitNexus)
- 本站源文件：`docs/` + `mkdocs.yml`（**仅此目录用于网页**）

```bash
pip install -r docs/requirements.txt
mkdocs serve
```

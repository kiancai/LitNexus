# LitNexus

**文献发现与筛选流水线**：从 Europe PMC 抓取期刊/关键词相关文章，SQLite 去重管理，AI 翻译标题与多问题分类初筛，导出 CSV 人工复筛后再导回。

---

## 当前阶段

| 阶段 | 状态 |
|------|------|
| 顶层设计与文档站 | **进行中**（本站） |
| 文档写清产品目的与架构 | 下一步 |
| Mac 原生版收尾 | 文档定型后 |
| Windows 原生版 | 目录已占位，按 Mac 定型后开发 |
| Python | **已降级**到 `python/`，非产品路径 |

> 开发节奏：**先文档与架构 → 再收尾 Mac → 最后 Windows**。  
> 代码仓库里的 `AGENTS.md` 是给 AI/开发者的压缩说明；**以本站为对外与对内的单一事实来源**。

---

## 文档怎么读

| 你想了解… | 去看 |
|-----------|------|
| 为什么做、解决什么问题 | [产品概述](product/overview.md) |
| 做什么 / 不做什么 | [目标与边界](product/scope.md) |
| 系统怎么拆、代码在哪 | [架构总览](architecture/overview.md) |
| 五步流水线 | [流水线与数据流](architecture/pipeline.md) |
| 工作区、配置、库表 | [工作区](architecture/workspace.md) · [数据库](architecture/database.md) |
| Mac / Windows / Python 策略 | [多端策略](architecture/platforms.md) |
| 怎么装、怎么跑 | [快速开始](guide/quickstart.md) |
| 接下来做什么 | [路线图](roadmap.md) |

---

## 仓库入口

- 源码：[github.com/kiancai/LitNexus](https://github.com/kiancai/LitNexus)
- 本站源文件：仓库内 `docs/` + 根目录 `mkdocs.yml`
- 本地预览文档：

```bash
pip install -r docs/requirements.txt
mkdocs serve
# 浏览器打开 http://127.0.0.1:8000
```

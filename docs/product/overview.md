# 产品概述与动机

## 问题

生物交叉与 AI 相关领域，大量重要工作会先出现在 **bioRxiv / medRxiv** 乃至 arXiv 上。PubMed 只部分收录（例如 NIH 资助的预印本）。若只靠 PubMed / WoS，容易漏掉前沿预印本；Google Scholar 又不适合做稳定的 API 自动化。

**核心冲突**：既要**尽量全覆盖**关注领域，又要能**程序化、可重复**地抓取与筛选。

## 方案选择

使用 **Europe PMC**：

- 在集成 PubMed 的基础上，进一步覆盖 bioRxiv、medRxiv 等
- 提供成熟的检索 API

在此之上，LitNexus 把流程固化为：

1. 按**关注期刊**与**关键词检索式**从 Europe PMC 拉取
2. **SQLite** 去重与统一管理
3. **AI** 翻译标题 + 多问题分类初筛
4. 导出 **CSV**，人工快速复筛，再**导回**数据库

AI 的 prompt / 分类问题写得好时，可大幅压缩人工阅读量；最终取舍仍由人决定（`include` 等标注列）。

## 产品一句话

> 用 Europe PMC + 本地工作区 + AI 初筛，做「关注领域文献的全覆盖式、可重复筛选」。

## 工作区模型（用户数据）

所有用户数据放在一个自包含目录（类似 Obsidian vault），便于备份、同步与跨机迁移，而不是散落在 `~/.config` 各处。

详见 [工作区与配置](../architecture/workspace.md)。

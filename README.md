# LitNexus

文献发现与筛选流水线：Europe PMC 抓取 → SQLite 去重 → AI 标题翻译与多问题初筛 → CSV 人工复筛回写。

**文档站（主说明）** → [https://kiancai.github.io/LitNexus/](https://kiancai.github.io/LitNexus/)

> 当前阶段：**架构整理与文档优先**，Mac 收尾与 Windows 复刻排在文档定型之后。详见 [路线图](https://kiancai.github.io/LitNexus/roadmap/)。

---

## 为什么做

生物交叉 / AI 领域大量工作先发在 bioRxiv 等预印本平台；仅靠 PubMed 会漏，Google Scholar 又不适合稳定 API 自动化。Europe PMC 在 PubMed 基础上覆盖预印本并提供 API。LitNexus 用期刊 + 关键词拉取、本地库管理、AI 初筛、人工终筛，做可重复的「关注领域全覆盖式」筛选。

---

## 仓库结构（简）

| 路径 | 说明 |
|------|------|
| `docs/` | 文档站源码（MkDocs Material） |
| `src/litnexus/` | Python 参考实现（CLI + GUI + core） |
| `mac/` | Mac 原生（SwiftUI，进行中） |
| `windows/` | Windows 原生（规划，暂缓） |
| `tests/` | Python 行为测试 |

完整架构说明见文档站 [架构总览](https://kiancai.github.io/LitNexus/architecture/overview/)。

---

## 快速上手（Python 参考）

```bash
uv sync
uv run litnexus init ~/LitNexus
# 编辑工作区内 journals.txt / keywords.txt，配置 API key
export LITNEXUS_API_KEY="your-key"
uv run litnexus run
```

```bash
uv run litnexus          # 图形界面
uv run litnexus --help   # CLI
```

更完整的步骤见 [快速开始](https://kiancai.github.io/LitNexus/guide/quickstart/)；迁移完成前也可参考仓库内 `TUTORIAL.md`。

### Mac 原生

```bash
cd mac && swift build
cd mac && swift run LitNexus selftest
cd mac && ./make_app.sh release
```

---

## 本地预览文档站

```bash
pip install -r docs/requirements.txt
mkdocs serve
```

推送到 `main` 且变更 `docs/**` 或 `mkdocs.yml` 时，GitHub Actions 会自动部署 Pages。

---

## 状态

| 组件 | 状态 |
|------|------|
| 文档站 | 建设中 |
| Python 参考 | 可用，作行为规范 |
| Mac 原生 | 引擎已验证，UI 待收尾 |
| Windows 原生 | 暂缓 |

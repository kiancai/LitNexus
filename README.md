<p align="center">
  <img src="mac/Assets/Brand/litnexus-mark.png" width="120" alt="LitNexus logo">
</p>

<h1 align="center">LitNexus</h1>

<p align="center">文献发现与筛选：Europe PMC → 本地工作区 → AI 初筛 → CSV 人工复筛。</p>

**文档** → [https://kiancai.github.io/LitNexus/](https://kiancai.github.io/LitNexus/)

---

## 仓库结构

```text
LitNexus/
├── docs/       文档站（MkDocs → GitHub Pages）
├── mac/        Mac 原生（当前产品）
├── win/        Windows 原生（占位，暂缓）
├── mkdocs.yml
└── README.md
```

| 目录 | 角色 |
|------|------|
| `mac/` | 主线：SwiftUI 桌面端 |
| `win/` | 下一阶段：按 Mac 复刻 |
| `docs/` | 目的、架构、使用、路线图（仅网页文档） |

节奏：**文档定型 → Mac 收尾 → Windows**。见 [路线图](https://kiancai.github.io/LitNexus/roadmap/)。

---

## Mac

```bash
cd mac
swift build
swift run LitNexus selftest
./make_app.sh release
```

---

## 文档站本地预览

```bash
pip install -r docs/requirements.txt
mkdocs serve
```

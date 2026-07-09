# LitNexus

文献发现与筛选：Europe PMC → 本地工作区 → AI 初筛 → CSV 人工复筛。

**文档** → [https://kiancai.github.io/LitNexus/](https://kiancai.github.io/LitNexus/)

---

## 仓库结构

```text
LitNexus/
├── docs/          文档站源码（主说明）
├── mac/           Mac 原生应用（当前产品）
├── windows/       Windows 原生（占位，暂缓）
├── python/        旧 Python 实现（已降级，仅对照）
├── mkdocs.yml
└── README.md
```

| 目录 | 角色 |
|------|------|
| `mac/` | **主线**：SwiftUI 桌面端 |
| `windows/` | 下一阶段：按 Mac 复刻 |
| `docs/` | 目的、架构、路线图 |
| `python/` | 历史参考，不是推荐用法 |

当前节奏：**文档定型 → Mac 收尾 → Windows**。见 [路线图](https://kiancai.github.io/LitNexus/roadmap/)。

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

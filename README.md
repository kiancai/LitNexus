<p align="center">
  <img src="mac/Assets/Brand/litnexus-mark.png" width="120" alt="LitNexus logo">
</p>

<h1 align="center">LitNexus</h1>

<p align="center">文献发现与筛选</p>

**详细文档：** → [https://kiancai.github.io/LitNexus/](https://kiancai.github.io/LitNexus/)

---

## 仓库结构

```text
LitNexus/
├── docs/       文档站（MkDocs → GitHub Pages）
├── mac/        Mac 原生（当前产品）
├── win/        Windows 原生（WPF：项目／基础配置／数据复筛闭环）
├── mkdocs.yml
└── README.md
```

| 目录 | 角色 |
|------|------|
| `mac/` | 主线：SwiftUI 桌面端 |
| `win/` | Windows 原生：按 Mac 的磁盘与行为契约独立复刻 |
| `docs/` | 目的、架构、使用、路线图（仅网页文档） |

节奏：**文档定型 → Mac 收尾 → Windows 基础工程 → 功能复刻**。见 [路线图](https://kiancai.github.io/LitNexus/roadmap/)。

---

## Mac

```bash
cd mac
swift build
swift run LitNexus selftest
./make_app.sh release
```

---

## Windows Preview（发布后）

发布 Windows Preview 后，可从 [GitHub Releases](https://github.com/kiancai/LitNexus/releases) 下载 `LitNexus-windows-net48-preview.zip`。**请完整解压 ZIP**，再从解压后的目录运行 `LitNexus.exe`；不要单独移动或运行其中一个 `.exe`，其余文件是运行所需依赖。

当前 Preview 仅供测试项目选择、基础配置、数据状态、CSV 导出与人工复筛导回。运行、统计、完整配置和数据库维护尚未完成全量对标。首次运行未签名测试版时，Windows 可能显示 SmartScreen 提示；请确认下载来源是本项目 Releases 后再继续。

同一个工作区可以在 Mac 与 Windows 间迁移，但**不能同时在两端写入**同一个包含 SQLite/WAL 数据库的工作区。

从源码构建和运行自检：

```powershell
cd win
.\build.ps1 -Configuration Release -SelfTest
```

Windows 端以 C# / WPF 独立实现；与 Mac 对齐的是工作区格式、数据安全契约和行为自检，而不是共享业务代码。

---

## 文档站本地预览

```bash
pip install -r docs/requirements.txt
mkdocs serve
```

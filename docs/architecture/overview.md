# 架构总览

## 分层

```text
┌─────────────────────────────────────────────────────────┐
│  UI（Mac SwiftUI / 未来 Windows WPF / Python NiceGUI）   │
├─────────────────────────────────────────────────────────┤
│  流水线编排（download → merge → translate → classify →  │
│              export；import 为独立回写）                   │
├─────────────────────────────────────────────────────────┤
│  领域能力：EPMC 客户端 · SQLite · AI 翻译/分类 · CSV IO  │
├─────────────────────────────────────────────────────────┤
│  工作区：litnexus.toml · journals/keywords · db · dirs  │
└─────────────────────────────────────────────────────────┘
```

UI 尽量薄；**行为规范以引擎/流水线语义为准**，各端分别实现。

## 仓库布局（目标清晰度）

当前仓库在「Python 参考 + Mac 原生进行中 + 文档站新建」阶段，目录职责如下：

| 路径 | 职责 |
|------|------|
| `docs/` + `mkdocs.yml` | **文档站源码**（本站）；产品/架构/使用的主文档 |
| `src/litnexus/` | **Python 参考实现**（CLI + NiceGUI + core） |
| `tests/` | Python 行为测试（原生移植时的标尺之一） |
| `mac/` | **Mac 原生**（SwiftPM + SwiftUI；引擎 + UI） |
| `windows/` | Windows 原生（规划中，暂缓） |
| `AGENTS.md` | 给编码 agent 的仓库内说明（压缩版，应服从本站） |
| `README.md` | GitHub 门面：一句话 + 状态 + 链到文档站 |
| `config.example.toml` | 配置示例 |
| `_legacy_data/` | 历史数据，**不入库**、不参与架构 |

```text
LitNexus/
├── docs/                 # 文档站（MkDocs）
├── mkdocs.yml
├── README.md
├── AGENTS.md
├── config.example.toml
├── src/litnexus/         # Python 参考
│   ├── cli/
│   ├── core/
│   └── gui/
├── tests/
├── mac/                  # Mac 原生
│   └── Sources/LitNexus/
│       ├── Engine/
│       └── UI/
└── windows/              # 预留（暂缓）
```

## 实现策略：方案 A（各自重写）

- **不做**跨语言共享引擎。
- Mac 用 **Swift**、Windows 用 **C#** 各写一份逻辑。
- 对齐依据：Python `core` 语义 + `tests/` + Mac `selftest`。
- 理由：逻辑规模可控；换最小体积与纯原生体验；两端同时大改成本高，故 **Mac 定型后再复刻 Windows**。

详见 [多端策略](platforms.md)。

## 配置与密钥（概念）

- 工作区根目录 `litnexus.toml` 为配置主文件。
- Python/CLI 仍支持环境变量覆盖 API key / base URL（见配置示例与 guide）。
- **Mac 桌面端**：以界面「AI 方案」为准，不依赖环境变量。

细节见 [工作区与配置](workspace.md)。

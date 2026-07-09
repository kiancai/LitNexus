# 快速开始

!!! note "文档站优先阶段"
    使用说明会从仓库根目录 `TUTORIAL.md` 逐步迁入本站并按「桌面优先」重排。本节先给出可跑通的最小路径。

## 方式 A：从源码（Python 参考）

需要 [uv](https://docs.astral.sh/uv/) 与 Python ≥ 3.11。

```bash
git clone https://github.com/kiancai/LitNexus.git
cd LitNexus
uv sync

# 创建工作区
uv run litnexus init ~/LitNexus

# 编辑 ~/LitNexus 下 journals.txt / keywords.txt
# 配置 API（环境变量或 litnexus.toml）
export LITNEXUS_API_KEY="your-key"

# 一键流水线
uv run litnexus run
```

图形界面：

```bash
uv run litnexus          # 默认 GUI
uv run litnexus gui
```

更完整的 CLI / 配置说明见仓库 `TUTORIAL.md`（迁移完成前）。

## 方式 B：Mac 原生应用

在 `mac/` 目录：

```bash
cd mac
swift build
swift run LitNexus selftest   # 引擎自检
./make_app.sh release         # 产出 LitNexus.app
```

或从 GitHub Releases 下载已构建的 `.app`（若已发布）。

首次打开 macOS 未签名应用时，可能需要右键 →「打开」。

## 下一步

- 理解数据放哪：[工作区](workspace.md)
- 理解五步在干什么：[流水线](../architecture/pipeline.md)

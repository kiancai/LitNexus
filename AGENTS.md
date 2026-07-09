# AGENTS.md

给编码 agent 的仓库说明。**产品与架构以文档站为准**：https://kiancai.github.io/LitNexus/

## 顶层结构

| 路径 | 含义 |
|------|------|
| `docs/` + `mkdocs.yml` | 文档站（事实源） |
| `mac/` | Mac 原生（当前产品主线） |
| `windows/` | Windows 原生（占位，暂缓） |
| `python/` | 旧 Python CLI/GUI（已降级，仅对照） |

根目录不要再堆业务代码或示例配置。

## 产品是什么

本地工作区流水线：Europe PMC 抓取 → SQLite 去重 → AI 译标题/多问题分类 → CSV 人工复筛回写。

## 策略

- **方案 A**：Mac / Windows 各自原生重写，不共享跨语言引擎；行为用 selftest / 对照对齐。
- **不做 Linux 客户端**（现阶段）。
- **Python 不作为产品路径**；需要查旧逻辑时看 `python/`。
- 开发顺序：**文档 → Mac 收尾 → Windows**。

## Mac 常用命令

```bash
cd mac && swift build
cd mac && swift run LitNexus selftest
cd mac && ./make_app.sh release
```

已定交互：AI 多方案、设置自动保存、桌面不读环境变量、merge 只处理新文件（`_merged/`）。

## 文档

```bash
pip install -r docs/requirements.txt
mkdocs serve
```

改 `docs/**` 推到 `main` 会部署 Pages。

## 工作区（用户数据）

自包含目录：`litnexus.toml`、`journals.txt`、`keywords.txt`、`litnexus.db`、`downloads/`、`exports/`。  
细节见文档站架构页，勿在根目录再复制长说明。

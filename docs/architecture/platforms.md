# 多端策略

## 目标

轻量原生桌面：双击即开、不捆绑沉重运行时。

## 方案 A：各端各自重写

| 平台 | 技术 | 状态 |
|------|------|------|
| **Mac**（`mac/`） | Swift + SwiftUI | 引擎已自检；UI 待文档定型后收尾 |
| **Windows**（`win/`） | C# + WPF，目标 .NET Framework 4.8 | 项目选择、基础配置和安全数据复筛闭环已接入；运行／统计与其余配置页待复刻 |
| **Linux** | — | 不做（现阶段） |

不共享跨语言引擎。对齐依据：文档中的磁盘/流水线契约 + Mac `selftest`。

## Mac 要点

- SPM + Command Line Tools 即可编译  
- 打包：`./make_app.sh release`  
- 已定交互：AI 多方案、设置自动保存、不读环境变量、merge 只处理新文件（`_merged/`）

## Windows 要点

- 独立重写 Core 与 WPF UI；不移植或共享 Swift 引擎。
- 已以 `litnexus.toml`、`litnexus.db`、CSV 复筛契约和 Mac `selftest` 建立无界面验收。
- 已接入项目选择与本机最近项目记录、基础检索配置、数据状态、范围导出、导出列选择，以及“预检 → 明确确认 → 自动备份 → 仅写入人工复筛列”的 CSV 导回闭环。
- 运行、统计、完整配置、数据库维护与打包仍按 Mac 已定交互逐页复刻；不要将当前可用的基础页面误认为全量对标。
- 工作区可以跨端打开，但 Mac 与 Windows 不能同时写同一个 SQLite/WAL 工作区。
- Win10/11 预装运行时方向 → 小体积 exe；开发使用 SDK 风格项目，发布前必须在干净 Windows 环境验证。

## Windows Preview 测试（发布后）

测试包将通过 [GitHub Releases](https://github.com/kiancai/LitNexus/releases) 提供为 `LitNexus-windows-net48-preview.zip`。用户应完整解压 ZIP 后运行 `LitNexus.exe`，不能只取出单个可执行文件。该 Preview 只覆盖项目选择、基础配置和数据复筛闭环；运行、统计、完整配置与数据库维护尚未完成全量对标。

## 文档与实现

```text
本站 ──决定──► Mac 收尾范围 ──定型后──► win 复刻
Mac selftest ──对齐──► 行为不漂移
```

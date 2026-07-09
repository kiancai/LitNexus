# 多端策略

## 为什么离开「仅 Python / NiceGUI」

NiceGUI 本质是 Web 方案：

- Windows 常依赖 WebView2，Win10 环境不一定齐
- 打包体积偏大（相对「十几 MB 级原生」目标）

目标：**轻量、优雅、双击即开、不依赖额外运行时**。

## 方案 A：各平台各自重写逻辑

| 平台 | 技术 | 状态 |
|------|------|------|
| **Mac** | Swift + SwiftUI，系统 AppKit 渲染 | 引擎完成并自检；UI 基本完整，待文档定型后收尾 |
| **Windows** | C# + WPF，目标 .NET Framework 4.8 | **暂缓**；Mac 定型后按蓝本复刻 |
| **Linux** | — | 暂不做 |
| **Python** | CLI + NiceGUI | **参考实现 / 行为规范**，稳定前不急退役 |

不共享引擎：逻辑简单、有测试标尺，优先最小体积与纯原生。

## Mac 要点

- 不需要完整 Xcode：Command Line Tools + SPM 即可编译
- 引擎：`mac/Sources/LitNexus/Engine/`（对照 Python core）
- UI：`mac/Sources/LitNexus/UI/`
- 自检：`swift run LitNexus selftest`；另有 epmc / AI 联网测试入口
- 打包：`./make_app.sh release` → `LitNexus.app`

已定交互（收尾时勿无故推翻，改则先改文档）：

- AI **多方案**模型，编辑即时持久化
- 设置**自动保存**（无底部大保存按钮）
- **不读环境变量**
- 合并**只处理新文件**（`_merged/`）

## Windows 要点（规划）

- 等 Mac 功能与形态稳定后再做，避免双端同时改
- 技术选型动机：.NET Framework 4.8 在 Win10/11 预装 → 小 exe、免装运行时
- 逻辑与 UI 动线复刻 Mac 定型版 + selftest 断言移植

## 文档与代码的关系

```text
本站架构/产品文档  ──决定──►  Mac 收尾范围
         │
         └──定型后──►  Windows 复刻
Python + tests + Mac selftest  ──对齐──►  行为不漂移
```

# 多端策略

## 目标

轻量原生桌面：双击即开、不捆绑沉重运行时。

## 方案 A：各端各自重写

| 平台 | 技术 | 状态 |
|------|------|------|
| **Mac**（`mac/`） | Swift + SwiftUI | 引擎已自检；UI 待文档定型后收尾 |
| **Windows**（`win/`） | C# + WPF，目标 .NET Framework 4.8 | 目录占位，**暂缓** |
| **Linux** | — | 不做（现阶段） |

不共享跨语言引擎。对齐依据：文档中的磁盘/流水线契约 + Mac `selftest`。

## Mac 要点

- SPM + Command Line Tools 即可编译  
- 打包：`./make_app.sh release`  
- 已定交互：AI 多方案、设置自动保存、不读环境变量、merge 只处理新文件（`_merged/`）

## Windows 要点

- Mac 定型后再做，避免双端同时改  
- Win10/11 预装运行时方向 → 小体积 exe  

## 文档与实现

```text
本站 ──决定──► Mac 收尾范围 ──定型后──► win 复刻
Mac selftest ──对齐──► 行为不漂移
```

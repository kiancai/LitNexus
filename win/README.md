# Windows 原生版

Windows 端按方案 A 独立实现：C# / WPF（目标 .NET Framework 4.8），不共享或移植 Swift 引擎。跨端对齐依据只有工作区磁盘格式、数据安全契约与 Mac `selftest`。

当前已完成无界面的 Core 与 `SelfTest`，并把第一批真实页面接到同一会话：项目选择／最近项目、基础检索配置、数据状态、四种范围 CSV 导出、导出列选择，以及“预检 → 明确确认 → 自动备份 → 仅回写 `include` / `tags`”的人工复筛导回。运行、统计、完整配置和数据库维护页面仍按 Mac 已定动线逐步复刻。

```text
win/
├── LitNexus.sln
├── build.ps1
├── src/
│   ├── LitNexus.Core/       # TOML、SQLite、CSV、流水线（不引用 WPF）
│   └── LitNexus.Desktop/    # Windows 原生界面
└── tests/
    ├── Fixtures/            # 跨端磁盘契约样本
    └── LitNexus.SelfTest/   # SSH / CI 可直接运行
```

## 本地构建

Windows 开发机可通过 `build.ps1` 找到系统 `dotnet`，或当前用户目录下的 `LitNexus\dotnet\dotnet.exe`：

```powershell
cd win
.\build.ps1 -Configuration Release -SelfTest
```

不要让 Mac 与 Windows 同时写同一个 SQLite/WAL 工作区；跨设备迁移应先退出客户端，再整体复制工作区或使用应用内数据库备份。

见文档站：[多端策略](https://kiancai.github.io/LitNexus/architecture/platforms/) · [数据库契约](https://kiancai.github.io/LitNexus/architecture/database/) · [路线图](https://kiancai.github.io/LitNexus/roadmap/)。

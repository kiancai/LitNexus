# 快速开始

当前产品主线是 **Mac 原生应用**；Windows 提供功能仍在逐页复刻的 Preview。

## Mac

```bash
cd mac
swift build
swift run LitNexus selftest
./make_app.sh release
```

或从 GitHub Releases 下载 `.app`（若已发布）。  
首次打开未签名应用：右键 →「打开」。

## Windows Preview（发布后）

从 [GitHub Releases](https://github.com/kiancai/LitNexus/releases) 下载 `LitNexus-windows-net48-preview.zip`，将 ZIP **完整解压**后运行其中的 `LitNexus.exe`。不要只复制或单独打开该 `.exe`，因为同目录的文件也是运行依赖。

这是测试版：目前可测试项目选择、基础配置、数据状态、CSV 导出和人工复筛导回；运行、统计、完整配置及数据库维护仍未完成全量对标。Windows 对未签名测试版可能显示 SmartScreen 提示；只应在确认下载来源为本项目 Releases 后选择继续。

## 工作区

在应用内创建或打开一个工作区目录（配置、数据库、下载、导出都在里面）。  
见 [工作区](workspace.md)。

一个工作区可以从 Mac 迁移到 Windows，反之亦然；但 SQLite/WAL 数据库不支持两端同时写入。切换设备前，请完全退出另一端的 LitNexus。

## 完成一轮人工复筛

运行下载、合并、翻译与分类后，可在“数据”页导出 CSV 进行人工复筛。导入只以 `epmc_id` 匹配文章，只读取 `include` 与 `tags`；其中 `include` 只能填写 `yes` 或 `no`，并会先预检再确认写入。完整填写、预检和冲突处理规则见[人工复筛与 CSV 导入](manual-review.md)。

## 下一步

- [工作区](workspace.md)
- [流水线](../architecture/pipeline.md)
- [人工复筛与 CSV 导入](manual-review.md)

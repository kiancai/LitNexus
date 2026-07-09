# 快速开始

产品入口是 **Mac 原生应用**。

## Mac

```bash
cd mac
swift build
swift run LitNexus selftest
./make_app.sh release
```

或从 GitHub Releases 下载 `.app`（若已发布）。  
首次打开未签名应用：右键 →「打开」。

## 工作区

在应用内创建或打开一个工作区目录（配置、数据库、下载、导出都在里面）。  
见 [工作区](workspace.md)。

## 下一步

- [工作区](workspace.md)
- [流水线](../architecture/pipeline.md)

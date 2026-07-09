# 快速开始

产品主线是 **Mac 原生应用**。Python 旧实现已降级，一般不必安装。

## Mac

```bash
cd mac
swift build
swift run LitNexus selftest   # 引擎自检
./make_app.sh release         # 产出 LitNexus.app
```

或从 GitHub Releases 下载 `.app`（若已发布）。  
首次打开未签名应用：右键 →「打开」。

## 工作区

首次使用在应用内创建或打开一个工作区目录（配置、数据库、下载、导出都在里面）。  
见 [工作区](workspace.md)。

## 旧 Python（不推荐）

仅对照：`cd python && uv sync`，说明见 `python/TUTORIAL.md`。

## 下一步

- [工作区](workspace.md)
- [流水线](../architecture/pipeline.md)

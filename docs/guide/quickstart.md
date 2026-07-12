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

## 完成一轮人工复筛

运行下载、合并、翻译与分类后，可在“数据”页导出 CSV 进行人工复筛。导入只以 `epmc_id` 匹配文章，只读取 `include` 与 `tags`；其中 `include` 只能填写 `yes` 或 `no`，并会先预检再确认写入。完整填写、预检和冲突处理规则见[人工复筛与 CSV 导入](manual-review.md)。

## 下一步

- [工作区](workspace.md)
- [流水线](../architecture/pipeline.md)
- [人工复筛与 CSV 导入](manual-review.md)

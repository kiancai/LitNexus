# 快速上手


## 1. 安装

=== ":material-download: 选择系统"

    选择你的系统，下载对应安装包

=== ":fontawesome-brands-apple: Mac"

    1. 打开 [GitHub Releases](https://github.com/kiancai/LitNexus/releases)  
    2. 下载 `.app` 或发布包并放到「应用程序」  
    3. 首次打开：若提示未验证开发者 :material-help-circle-outline:{ title="当前多为 ad-hoc 签名，不是 Apple 公证版。在 Finder 中右键 App → 打开 → 确认打开即可。" }，用 **右键 → 打开**

=== ":fontawesome-brands-windows: Windows"

    1. 打开 [GitHub Releases](https://github.com/kiancai/LitNexus/releases)，下载 `LitNexus-windows-net48-preview.zip`。
    2. 完整解压 ZIP，在解压目录里双击 `LitNexus.exe`；保留同目录的 DLL 和其他依赖。
    3. Preview 支持项目选择、基础配置、数据状态、CSV 导出和人工复筛导回；运行、统计、完整配置和数据库维护仍未完整实现。下文的完整工作流以 Mac 为准。

=== ":material-console: 源码构建"

    也支持使用源码构建的方式使用，如您不知道这是什么意思，则无需关注这里。

    在源码仓库根目录打开终端。Mac 需要 Swift / Xcode Command Line Tools：

    ```bash
    cd mac
    swift build
    swift run LitNexus selftest
    ./make_app.sh release
    ```

    应用包生成在 `mac/LitNexus.app`。Windows 开发环境见仓库 [Windows README](https://github.com/kiancai/LitNexus/tree/main/win)。

    ```powershell
    cd win
    .\build.ps1 -Configuration Release -SelfTest
    ```

---

## 2. 创建或打开工作区

工作区是一个文件夹，用来存储你的 LitNexus 数据库、配置信息等

1. 启动 LitNexus  
2. 选择 **新建** 或 **打开** 已有目录
3. 最好选择空目录打开  
4. 备份 / 换机时，先完全退出应用，再复制整个工作区；运行中的数据库请使用应用内备份。

!!! note "跨端注意"
    同一工作区可以在 Mac 与 Windows 间迁移，但 **不要两端同时写** 同一个带 SQLite/WAL 的目录。换机前请完全退出另一端。

工作区磁盘布局见 [工作区与配置](../reference/workspace.md)。

---

## 3. 首次设置

首次向导依次设置 **检索范围**、**筛选问题** 和 **模型服务**。筛选问题默认提供一个示例，但可以删为零个或添加多个；模型服务也支持保存多个，并选择一个作为当前运行使用的服务。三个步骤都可跳过并在之后的「配置」页调整。

详见 [首次设置](../guide/setup.md)。

---

## 4. 最小配置

在「配置」里至少准备：

| 项 | 做什么 |
|----|--------|
| 期刊 / 关键词 | 填你关注的列表与检索式 |
| AI（可选） | 要翻译 / 分类时配置方案与密钥；可稍后 |

!!! abstract "默认流水线"
    `download → merge → translate → classify`
    CSV 导出和复筛导回在「数据」页单独执行。没有配置模型服务时，可先单独下载和合并。

---

## 5. 跑一轮

1. 打开 **运行** 页，按步骤执行（或按界面提供的一键顺序）  
2. 到 **数据** 页查看库内文章状态  
3. 需要人工标注时：导出 CSV → 表格里改 `include` / `tags` → 再导回  

!!! success "导回安全要点（记住这三条即可）"
    - 只靠 `epmc_id` 匹配文章  
    - 只写 `include`（`yes`/`no`）与 `tags`；空 `include` 不改原值  
    - 先预检，有冲突再确认；默认不覆盖已有标注  

导出范围与备份操作见[数据指南](../guide/data.md)，CSV 填写和冲突处理见[人工复筛说明](../guide/manual-review.md)。

---

## 6. 自检（开发者可选）

```bash
# Mac
cd mac && swift run LitNexus selftest
```

```powershell
# Windows
cd win
.\build.ps1 -Configuration Release -SelfTest
```

---

## 接下来

- 卡住了 → [常见问题](faq.md)  
- 想继续读文档地图 → [概览](../index.md)  
- 查界面细节 → 顶栏 **使用指南**（运行 / 数据 / 统计 / 配置）  

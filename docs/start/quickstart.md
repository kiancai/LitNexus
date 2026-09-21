# 快速上手


## 1. 安装

=== ":material-download: 选择系统"

    选择你的系统，下载对应安装包

=== ":fontawesome-brands-apple: Mac"

    1. 打开 [GitHub Releases](https://github.com/kiancai/LitNexus/releases)  
    2. 下载 `.app` 或发布包并放到「应用程序」  
    3. 首次打开：若提示未验证开发者 :material-help-circle-outline:{ title="当前多为 ad-hoc 签名，不是 Apple 公证版。在 Finder 中右键 App → 打开 → 确认打开即可。" }，用 **右键 → 打开**

=== ":fontawesome-brands-windows: Windows"

    1. 步骤1
    2. 步骤2

=== ":material-console: 源码构建"

    也支持使用源码构建的方式使用，如您不知道这是什么意思，则无需关注这里。

    - Mac
        1. 步骤1
        2. 步骤2
    - Windows
        1. 步骤1
        2. 步骤2

---

## 2. 创建或打开工作区

工作区是一个文件夹，用来存储你的 LitNexus 数据库、配置信息等

1. 启动 LitNexus  
2. 选择 **新建** 或 **打开** 已有目录
3. 最好选择空目录打开  
3. 之后备份 / 换机：拷贝整个工作区目录即可  

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
    `download → merge → translate → classify → export`  
    **导入复筛 CSV** 不在默认 run 里，在数据页单独做。

---

## 5. 跑一轮

1. 打开 **运行** 页，按步骤执行（或按界面提供的一键顺序）  
2. 到 **数据** 页查看库内文章状态  
3. 需要人工标注时：导出 CSV → 表格里改 `include` / `tags` → 再导回  

!!! success "导回安全要点（记住这三条即可）"
    - 只靠 `epmc_id` 匹配文章  
    - 只写 `include`（`yes`/`no`）与 `tags`；空 `include` 不改原值  
    - 先预检，有冲突再确认；默认不覆盖已有标注  

更细的规则以后会放在使用指南 / 现有 [人工复筛说明](../guide/manual-review.md)。

---

## 5. 自检（开发者可选）

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

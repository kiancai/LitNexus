# 常见问题

用折叠问答整理高频问题。点标题展开；之后可按你的真实反馈继续增删。

---

## 安装与启动

???+ question "Mac 打开提示「无法验证开发者」或「已损坏」怎么办？"
    当前发布多为 **ad-hoc 签名**，不是 Apple 公证过的正式分发。

    1. 在 Finder 中 **右键** App → **打开** → 确认打开  
    2. 或到 **系统设置 → 隐私与安全性** 里允许仍要打开  
    3. 若仍失败，用源码 `./make_app.sh release` 本地再打一包对比  

    不要从不明来源下载冒名安装包。

??? question "Windows 只有一个 exe，双击报错或缺 DLL？"
    Preview 包必须 **整包解压** 后再运行目录里的 `LitNexus.exe`。  
    单独拷走 exe、删掉同目录依赖文件都会坏。

??? question "Windows SmartScreen 拦截正常吗？"
    未签名测试版常见。请确认下载地址是本项目 [Releases](https://github.com/kiancai/LitNexus/releases) 后再选择仍要运行。

??? question "需要装 .NET / Java / Python 才能用吗？"
    - **Mac 用户端**：原生 App，一般不要求你再装运行时（开发构建需要 Xcode CLT / Swift）。  
    - **Windows Preview**：面向已带 .NET Framework 4.8 的 Win10/11；以发布说明为准。  
    - 文档站预览才需要本机 Python + MkDocs。

---

## 工作区与数据

???+ question "工作区是什么？和「安装目录」有什么区别？"
    工作区是你的 **数据目录**（配置、库、下载、导出都在里面），不是程序安装位置。  
    换电脑时拷工作区即可带走数据；程序本身重新安装即可。

??? question "能不能把工作区放进 iCloud / OneDrive / 网盘？"
    可以备份，但 **正在运行时** 不建议让同步盘同时改 SQLite（易损坏）。  
    较好做法：退出应用 → 同步/拷贝 → 再打开。

??? question "Mac 和 Windows 能同时打开同一个工作区吗？"
    **不能同时写**。SQLite/WAL 不支持双端并发写。  
    换端前请完全退出另一端的 LitNexus。

??? question "误删了文章 / 导错了 CSV 怎么办？"
    - 导回前应用会走预检；有冲突需你确认  
    - Windows 复筛导回路径含自动备份（以当前版本行为为准）  
    - 仍建议重要工作区自行做目录级备份  

---

## 流水线与 AI

??? question "一定要配置 AI 才能用吗？"
    不一定。下载、合并、导出与人工标注可以不依赖 AI。  
    翻译标题、多问题分类需要可用的模型服务与密钥。

??? question "AI 密钥会上传到你们服务器吗？"
    不会。桌面端走你配置的 API；**没有** LitNexus 账号体系或中转强制上传。  
    密钥保存在工作区 / 本机配置中，请自行保管。

??? question "为什么 merge 之后 downloads 里文件「少了」？"
    合并只处理新文件；已合并的 JSONL 会进入 `downloads/_merged/`，避免重复劳动。这是预期行为。

---

## 人工复筛（CSV）

???+ question "CSV 里哪些列会被写回数据库？"
    匹配键：`epmc_id`。  
    写入：`include`（仅 `yes` / `no`）、`tags`。  
    其它列可在表格里随便用，导回时忽略。

??? question "include 留空会怎样？"
    **不改变**库里原有 `include`。只有显式 `yes` / `no` 才更新。

??? question "预检失败还能强制导入吗？"
    重复 ID、非法值、缺必要列等会 **阻止写入**。先修好 CSV 再导。  
    未匹配 ID、覆盖冲突会提示；覆盖需你明确打开并确认。

??? question "改了配置里的分类问题，会不会把历史答案清掉？"
    设计原则是：配置变更 **不应静默抹掉** 历史结果；问题默认归档而非硬删。  
    细节见原理中的数据库 / 生命周期说明；部分迁移能力仍在路线图中。

---

## 文档与贡献

??? question "英文文档为什么和中文不完全一样？"
    当前优先定中文结构与表述；英文会在中文定型后对齐。

??? question "想报 bug / 提功能去哪？"
    [GitHub Issues](https://github.com/kiancai/LitNexus/issues)。  
    复现步骤、系统版本、是否 selftest 通过，能大幅加快处理。

??? question "文档里的「组件示例」是产品功能吗？"
    不是。那是 **文档站版式选型页**，方便挑选 admonition、折叠、卡片等写法，与 LitNexus 软件功能无关。

---

## 还没写到的问题

!!! tip "欢迎补充"
    把你卡住的步骤发 Issue 或直接改本页 PR。  
    结构建议：`??? question "简短问法"` + 可操作的答案。

# 架构总览

## 顶层设计（只记这些）

LitNexus 有三层，不要混在一起：

1. **产品语义**（与语言无关）  
   工作区 + 五步流水线 + SQLite + AI 初筛 + CSV 人工闭环。

2. **实现**（按平台各自一份）  
   - `mac/` — 当前主线  
   - `windows/` — 下一阶段  
   - `python/` — 旧实现，已降级，只作对照  

3. **文档**（`docs/`）  
   目的、边界、不变量、路线图；改产品意图先改文档。

```text
        文档 docs/
            │ 约束
   ┌────────┼────────┐
   ▼        ▼        ▼
  mac/   windows/  python/
 主线     暂缓      降级对照
```

## 仓库目录

```text
LitNexus/
├── docs/          # 文档站
├── mac/           # Mac 原生
├── windows/       # Windows 占位
├── python/        # 旧 Python（非产品）
├── mkdocs.yml
└── README.md
```

## 产品分层（概念）

```text
UI（Mac / 未来 Windows）
  → 流水线编排
    → EPMC · 数据库 · AI · CSV
      → 工作区磁盘契约
```

磁盘契约（工作区长什么样、流水线五步、库表意图）是各端必须共认的部分；代码不共享，语义要一致。

## 多端策略

- **方案 A**：各端重写，测试对齐，追求轻量原生。
- Mac 定型后再做 Windows，避免双端同时改。
- 详见 [多端策略](platforms.md)。

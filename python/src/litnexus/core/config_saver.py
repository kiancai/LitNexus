"""Config 保存为 TOML 文件。"""

from __future__ import annotations

from pathlib import Path

import tomli_w

from litnexus.core.config import Config


def save_config(cfg: Config, path: Path) -> None:
    """将 Config 对象保存为 TOML 文件。

    直接用 model_dump() 序列化，避免手写字段清单与模型脱节（新增字段时漏写）。
    唯一的特例：模型字段 schema_cfg 对应 TOML 里的 [schema] 表（与 load_config 对称）。
    """
    data = cfg.model_dump()
    data["schema"] = data.pop("schema_cfg")

    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as f:
        tomli_w.dump(data, f)

"""配置加载与验证模块。

优先级（高 → 低）：
  API key:  LITNEXUS_API_KEY > ARK_API_KEY > config.toml [ai].api_key
  Base URL: LITNEXUS_BASE_URL > ARK_API_BASE_URL > config.toml [ai].base_url
  配置路径: --config 命令行参数 > LITNEXUS_CONFIG 环境变量 > ~/.config/litnexus/config.toml
"""

from __future__ import annotations

import os
import tomllib
from pathlib import Path
from typing import Optional

from pydantic import BaseModel, field_validator


# ── 默认路径 ──────────────────────────────────────────────────────────────────
DEFAULT_CONFIG_DIR = Path.home() / ".config" / "litnexus"
DEFAULT_CONFIG_PATH = DEFAULT_CONFIG_DIR / "config.toml"
DEFAULT_DATA_DIR = Path.home() / ".local" / "share" / "litnexus"


# ── Pydantic 模型 ─────────────────────────────────────────────────────────────

class PathsConfig(BaseModel):
    db: Path = DEFAULT_DATA_DIR / "epmc_articles.db"
    download_dir: Path = DEFAULT_DATA_DIR / "download"
    export_dir: Path = DEFAULT_DATA_DIR / "export"
    journals_file: Path = DEFAULT_CONFIG_DIR / "journals.txt"
    keywords_files: list[Path] = [DEFAULT_CONFIG_DIR / "keywords_1.txt"]

    @field_validator("db", "download_dir", "export_dir", "journals_file", mode="before")
    @classmethod
    def expand_path(cls, v: str | Path) -> Path:
        return Path(v).expanduser()

    @field_validator("keywords_files", mode="before")
    @classmethod
    def expand_paths(cls, v: list) -> list[Path]:
        return [Path(p).expanduser() for p in v]


class DownloadConfig(BaseModel):
    days: int = 30
    page_size: int = 1000
    request_delay: float = 0.5


class AIConfig(BaseModel):
    api_key: str = ""
    base_url: str = "https://ark.cn-beijing.volces.com/api/v3"
    model: str = "doubao-1-5-pro-32k-character-250715"


class TranslateConfig(BaseModel):
    batch_size: int = 30
    concurrency: int = 20


class Question(BaseModel):
    """一个分类问题，id 用作数据库列前缀（{id}_ans, {id}_rea）。"""
    id: str
    text: str


class ClassifyConfig(BaseModel):
    max_workers: int = 100
    questions: list[Question] = [
        Question(
            id="q1",
            text=(
                "请判断本文是否属于'计算生物学、生物信息学、生物医学'或相关交叉领域。"
                "若文章属于以下任一类型，请回答'是'：(1) 涉及组学数据（基因/蛋白/代谢等）的分析或实验研究；"
                "(2) 涉及生物算法、模型、软件工具或数据库的开发与应用；"
                "(3) 对上述相关领域的综述、系统评价、进展总结或观点展望。"
                "仅当文章是纯粹的临床护理个案、社会学调查、或完全不涉及生物医学背景的纯数学/计算机理论时，才回答'否'。"
            ),
        ),
        Question(
            id="q2",
            text=(
                "请判断本文是否属于以下任一核心关注领域（命中任意一项即回答'是'）："
                "(a) 微生物组学（Microbiome）：涵盖人体或环境微生物群落、宏基因组/宏转录组分析、菌群功能预测；"
                "(b) 生物基础模型与生成式AI：涉及针对DNA/RNA/蛋白质序列的语言模型，"
                "或针对单细胞/空间组学的预训练/嵌入模型；"
                "(c) 生物医学机器学习应用：使用深度学习/AI解决具体生物问题，或相关算法基准测试；"
                "(d) 病毒与病原体计算：涉及病毒组、病原体检测、耐药基因或流行病学建模；"
                "(e) 生物信息核心工具：涉及序列比对、数据质控、流程管理或多组学整合分析。"
                "若均不属于，回答'否'。"
            ),
        ),
    ]


class SchemaConfig(BaseModel):
    """用户自定义注释列（TEXT 类型，启动时自动添加到数据库）。"""
    custom_columns: list[str] = ["include", "tags"]


class ExportConfig(BaseModel):
    filter: str = "pending"  # pending | all | 自定义 SQL WHERE 子句
    exclude_columns: list[str] = [
        "journal_info_json",
        "keyword_list_json",
        "abstract_zh",
    ]


class Config(BaseModel):
    paths: PathsConfig = PathsConfig()
    download: DownloadConfig = DownloadConfig()
    ai: AIConfig = AIConfig()
    translate: TranslateConfig = TranslateConfig()
    classify: ClassifyConfig = ClassifyConfig()
    schema_cfg: SchemaConfig = SchemaConfig()
    export: ExportConfig = ExportConfig()


# ── 加载函数 ──────────────────────────────────────────────────────────────────

class ConfigError(Exception):
    pass


def load_config(path: Optional[Path] = None) -> Config:
    """加载配置文件，返回 Config 对象。"""
    config_path: Path | None = path
    if config_path is None:
        env_path = os.environ.get("LITNEXUS_CONFIG")
        if env_path:
            config_path = Path(env_path).expanduser()
        elif DEFAULT_CONFIG_PATH.exists():
            config_path = DEFAULT_CONFIG_PATH

    raw: dict = {}
    if config_path is not None:
        if not config_path.exists():
            raise ConfigError(f"配置文件不存在：{config_path}")
        with open(config_path, "rb") as f:
            raw = tomllib.load(f)

    # TOML 中 [schema] 对应模型字段 schema_cfg
    if "schema" in raw and "schema_cfg" not in raw:
        raw["schema_cfg"] = raw.pop("schema")

    cfg = Config.model_validate(raw)

    cfg.ai.api_key = (
        os.environ.get("LITNEXUS_API_KEY")
        or os.environ.get("ARK_API_KEY")
        or cfg.ai.api_key
    )
    cfg.ai.base_url = (
        os.environ.get("LITNEXUS_BASE_URL")
        or os.environ.get("ARK_API_BASE_URL")
        or cfg.ai.base_url
    )

    return cfg


def get_api_key(cfg: Config) -> str:
    """返回有效的 API key，找不到则抛出 ConfigError。"""
    key = cfg.ai.api_key
    if not key:
        raise ConfigError(
            "未找到 API key。请通过以下任一方式设置：\n"
            "  1. 环境变量 LITNEXUS_API_KEY 或 ARK_API_KEY\n"
            "  2. config.toml 中的 [ai].api_key 字段"
        )
    return key


# ── init-config 默认文件内容 ──────────────────────────────────────────────────

DEFAULT_CONFIG_TOML = """\
# LitNexus 配置文件
# 运行 `litnexus init-config` 生成此文件

[paths]
db = "~/.local/share/litnexus/epmc_articles.db"
download_dir = "~/.local/share/litnexus/download"
export_dir = "~/.local/share/litnexus/export"
journals_file = "~/.config/litnexus/journals.txt"
keywords_files = [
    "~/.config/litnexus/keywords_1.txt",
]

[download]
days = 30
page_size = 1000
request_delay = 0.5

[ai]
# 留空则依赖 LITNEXUS_API_KEY 或 ARK_API_KEY 环境变量
api_key = ""
base_url = "https://ark.cn-beijing.volces.com/api/v3"
model = "doubao-1-5-pro-32k-character-250715"

[translate]
batch_size = 30
concurrency = 20

[classify]
max_workers = 100

[[classify.questions]]
id = "q1"
text = "请判断本文是否属于'计算生物学、生物信息学、生物医学'或相关交叉领域。若文章属于以下任一类型，请回答'是'：(1) 涉及组学数据（基因/蛋白/代谢等）的分析或实验研究；(2) 涉及生物算法、模型、软件工具或数据库的开发与应用；(3) 对上述相关领域的综述、系统评价、进展总结或观点展望。仅当文章是纯粹的临床护理个案、社会学调查、或完全不涉及生物医学背景的纯数学/计算机理论时，才回答'否'。"

[[classify.questions]]
id = "q2"
text = "请判断本文是否属于以下任一核心关注领域（命中任意一项即回答'是'）：(a) 微生物组学（Microbiome）；(b) 生物基础模型与生成式AI；(c) 生物医学机器学习应用；(d) 病毒与病原体计算；(e) 生物信息核心工具。若均不属于，回答'否'。"

[schema]
# 用户自定义注释列，可自由增加（均为 TEXT 类型）
custom_columns = ["include", "tags"]

[export]
filter = "pending"
exclude_columns = [
    "journal_info_json",
    "keyword_list_json",
    "abstract_zh",
]
"""

DEFAULT_JOURNALS_TXT = """\
# 期刊列表（每行一个，# 开头为注释）
# 期刊名称需与 Europe PMC 数据库中的名称完全一致
# 示例：
# Nature
# Nature microbiology
# Cell
"""

DEFAULT_KEYWORDS_TXT = """\
# 关键词检索式（每行一个，支持 Europe PMC 布尔表达式语法）
# 示例：
# (microbiome OR microbiota) AND "machine learning"
# TITLE:(deep learning) AND ABSTRACT:(single cell)
"""

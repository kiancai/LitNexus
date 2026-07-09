"""配置加载与验证模块。

配置随工作区走：每个工作区根目录下有一个 litnexus.toml。
环境变量覆盖（高 → 低）在「使用时」由 get_api_key()/get_base_url()/resolved_ai()
解析，而**不**在 load_config 时注入 Config 字段，以免被 save_config 误写回磁盘：
  API key:  LITNEXUS_API_KEY > ARK_API_KEY > litnexus.toml [ai].api_key
  Base URL: LITNEXUS_BASE_URL > ARK_API_BASE_URL > litnexus.toml [ai].base_url
"""

from __future__ import annotations

import os
import re
import tomllib
from pathlib import Path

from pydantic import BaseModel, ValidationError, field_validator

# 合法 SQL 标识符（用作数据库列名 / 列前缀），防止列名拼进 SQL 时出错或注入
_IDENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def _check_identifier(value: str, what: str) -> str:
    if not _IDENT_RE.match(value):
        raise ValueError(
            f"{what}必须是合法标识符（字母或下划线开头，仅含字母、数字、下划线）：{value!r}"
        )
    return value


# ── Pydantic 模型 ─────────────────────────────────────────────────────────────

class DownloadConfig(BaseModel):
    days: int = 30
    page_size: int = 1000
    request_delay: float = 0.5


class AIConfig(BaseModel):
    # 无内置默认值：每个用户必须自行填写自己的服务商接口与模型，避免新装即指向某家服务。
    api_key: str = ""
    base_url: str = ""
    model: str = ""


class TranslateConfig(BaseModel):
    batch_size: int = 30
    concurrency: int = 20


class Question(BaseModel):
    """一个分类问题，id 用作数据库列前缀（{id}_ans, {id}_rea）。"""
    id: str
    text: str

    @field_validator("id")
    @classmethod
    def _validate_id(cls, v: str) -> str:
        return _check_identifier(v, "分类问题 id")


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

    @field_validator("custom_columns")
    @classmethod
    def _validate_columns(cls, v: list[str]) -> list[str]:
        return [_check_identifier(c, "自定义列名") for c in v]


class ExportConfig(BaseModel):
    filter: str = "pending"  # pending | all | 自定义 SQL WHERE 子句
    exclude_columns: list[str] = [
        "journal_info_json",
        "keyword_list_json",
        "abstract_zh",
    ]


class Config(BaseModel):
    download: DownloadConfig = DownloadConfig()
    ai: AIConfig = AIConfig()
    translate: TranslateConfig = TranslateConfig()
    classify: ClassifyConfig = ClassifyConfig()
    schema_cfg: SchemaConfig = SchemaConfig()
    export: ExportConfig = ExportConfig()


# ── 加载函数 ──────────────────────────────────────────────────────────────────

class ConfigError(Exception):
    pass


def load_config(config_path: Path) -> Config:
    """加载某工作区的 litnexus.toml，返回 Config 对象。

    环境变量覆盖**不**在此注入 Config 字段（否则会被 save_config 写回磁盘，
    造成环境变量里的密钥泄漏）。运行期请用 get_api_key()/get_base_url()/
    resolved_ai() 解析有效值。
    """
    if not config_path.exists():
        raise ConfigError(f"配置文件不存在：{config_path}")
    try:
        with open(config_path, "rb") as f:
            raw = tomllib.load(f)
    except tomllib.TOMLDecodeError as e:
        raise ConfigError(f"配置文件 TOML 语法错误（{config_path}）：{e}") from e

    # TOML 中 [schema] 对应模型字段 schema_cfg
    if "schema" in raw and "schema_cfg" not in raw:
        raw["schema_cfg"] = raw.pop("schema")

    try:
        return Config.model_validate(raw)
    except ValidationError as e:
        raise ConfigError(f"配置文件校验失败（{config_path}）：\n{e}") from e


def get_api_key(cfg: Config) -> str:
    """返回有效的 API key（环境变量优先），找不到则抛出 ConfigError。

    优先级：LITNEXUS_API_KEY > ARK_API_KEY > litnexus.toml [ai].api_key
    """
    key = (
        os.environ.get("LITNEXUS_API_KEY")
        or os.environ.get("ARK_API_KEY")
        or cfg.ai.api_key
    )
    if not key:
        raise ConfigError(
            "未找到 API key。请通过以下任一方式设置：\n"
            "  1. 环境变量 LITNEXUS_API_KEY 或 ARK_API_KEY\n"
            "  2. litnexus.toml 中的 [ai].api_key 字段"
        )
    return key


def get_base_url(cfg: Config) -> str:
    """返回有效的 AI base URL（环境变量优先）。

    优先级：LITNEXUS_BASE_URL > ARK_API_BASE_URL > litnexus.toml [ai].base_url
    """
    return (
        os.environ.get("LITNEXUS_BASE_URL")
        or os.environ.get("ARK_API_BASE_URL")
        or cfg.ai.base_url
    )


def resolved_ai(cfg: Config) -> AIConfig:
    """返回一份解析了环境变量覆盖的 AIConfig 副本（供运行期调用 AI 使用）。

    刻意不修改传入的 cfg —— 避免把仅存在于环境变量里的密钥/URL 注入 Config 字段，
    进而被 save_config 落盘（环境变量泄漏）。
    """
    return cfg.ai.model_copy(
        update={"api_key": get_api_key(cfg), "base_url": get_base_url(cfg)}
    )


# ── init-config 默认文件内容 ──────────────────────────────────────────────────

DEFAULT_CONFIG_TOML = """\
# LitNexus 配置文件（位于工作区根目录）
# 由 `litnexus init` 生成，也可用 GUI 编辑

[download]
days = 30
page_size = 1000
request_delay = 0.5

[ai]
# 无默认值，请填写你自己的 OpenAI 兼容服务商接口。
# api_key 留空则依赖 LITNEXUS_API_KEY 或 ARK_API_KEY 环境变量。
api_key = ""
base_url = ""
model = ""

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

# 检索列表模板：预填几条通用示例，让新用户一眼看懂格式，可直接增删。
DEFAULT_JOURNALS_TXT = """\
# 每行一个期刊名，需与 Europe PMC 中的名称完全一致；# 开头为注释、空行忽略。
# 下面是示例，请按需增删：
Nature
Bioinformatics
Genome Biology
Nucleic Acids Research
"""

DEFAULT_KEYWORDS_TXT = """\
# 每行一个 Europe PMC 检索式，支持布尔语法（AND/OR/NOT）与引号短语；# 开头为注释。
# 下面是示例，请按需增删：
(microbiome OR microbiota) AND "machine learning"
"single cell" AND (deep learning OR neural network)
"""

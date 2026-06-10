"""EPMC 可选字段注册表。

分析必需的字段（title / abstract / pub_year / journal_title 等）由
``io.parse_article`` 始终抓取并入库。本模块定义的是**可选**字段——用户可在
``[ingest].extra_fields`` 中按需勾选，每个字段知道自己的数据库列名、SQL 类型、
面向用户的说明，以及如何从 Europe PMC 原始 JSON 中提取值。

GUI 的「字段勾选」页直接读取 ``available_extra_fields()`` 渲染选项。
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class FieldSpec:
    id: str  # 配置中使用的名字，同时作为数据库列名
    sql_type: str  # SQLite 列类型
    description: str  # 面向用户的说明（GUI 中展示）
    extract: Callable[[dict], Any]  # 从原始 JSON 提取该字段的值


def _str(key: str) -> Callable[[dict], Any]:
    def extract(raw: dict) -> str | None:
        v = raw.get(key)
        return str(v) if v not in (None, "") else None

    return extract


def _int(key: str) -> Callable[[dict], Any]:
    def extract(raw: dict) -> int | None:
        v = raw.get(key)
        try:
            return int(v) if v is not None and str(v).strip() != "" else None
        except (ValueError, TypeError):
            return None

    return extract


def _pub_types(raw: dict) -> str | None:
    items = (raw.get("pubTypeList") or {}).get("pubType") or []
    vals = [str(x) for x in items if x]
    return "; ".join(vals) or None


def _mesh_terms(raw: dict) -> str | None:
    headings = (raw.get("meshHeadingList") or {}).get("meshHeading") or []
    terms = [h.get("descriptorName") for h in headings if h.get("descriptorName")]
    return "; ".join(terms) or None


def _issn(raw: dict) -> str | None:
    journal = (raw.get("journalInfo") or {}).get("journal") or {}
    return journal.get("issn") or journal.get("essn") or None


OPTIONAL_FIELDS: dict[str, FieldSpec] = {
    spec.id: spec
    for spec in (
        FieldSpec("cited_by_count", "INTEGER", "被引次数 (citedByCount)", _int("citedByCount")),
        FieldSpec("is_open_access", "TEXT", "是否开放获取 (isOpenAccess)", _str("isOpenAccess")),
        FieldSpec("in_epmc", "TEXT", "全文是否在 EPMC (inEPMC)", _str("inEPMC")),
        FieldSpec("has_pdf", "TEXT", "是否有 PDF (hasPDF)", _str("hasPDF")),
        FieldSpec("pub_type", "TEXT", "文献类型 (pubTypeList)", _pub_types),
        FieldSpec("mesh_terms", "TEXT", "MeSH 主题词 (meshHeadingList)", _mesh_terms),
        FieldSpec("language", "TEXT", "语言 (language)", _str("language")),
        FieldSpec("issn", "TEXT", "期刊 ISSN", _issn),
    )
}


def available_extra_fields() -> list[tuple[str, str]]:
    """返回 [(id, description)]，供 GUI 渲染勾选项。"""
    return [(spec.id, spec.description) for spec in OPTIONAL_FIELDS.values()]


def active_extra_fields(extra_field_ids: list[str]) -> list[FieldSpec]:
    """把配置中的字段 id 列表解析为 FieldSpec（忽略未知 id）。"""
    return [OPTIONAL_FIELDS[fid] for fid in extra_field_ids if fid in OPTIONAL_FIELDS]

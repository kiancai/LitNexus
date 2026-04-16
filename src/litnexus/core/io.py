"""JSONL 读写与 CSV 导出辅助模块。"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Iterator

import pandas as pd


def iter_jsonl(filepath: Path) -> Iterator[dict]:
    """逐行读取 JSONL，跳过空行和解析错误行。"""
    with open(filepath, encoding="utf-8") as f:
        for i, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                print(f"  警告：{filepath.name} 第 {i} 行 JSON 格式错误，已跳过", file=sys.stderr)


def parse_article(raw: dict) -> dict:
    """将 EPMC API 原始 JSON 映射到 DB schema 字段。"""
    epmc_id = raw.get("id")
    pmid = raw.get("pmid") or None
    doi = raw.get("doi") or None
    pmcid = raw.get("pmcid") or None

    pub_year_str = raw.get("pubYear", "")
    pub_year = int(pub_year_str) if pub_year_str and pub_year_str.isdigit() else None

    journal_info = raw.get("journalInfo") or {}
    journal_title = None
    if journal_info and "journal" in journal_info:
        journal_title = journal_info["journal"].get("title")

    # 兼容期刊下载脚本注入的 query_journal_name
    query_term = raw.get("query_search_term") or raw.get("query_journal_name")

    return {
        "epmc_id": epmc_id,
        "pmid": pmid,
        "doi": doi,
        "source": raw.get("source"),
        "pmcid": pmcid,
        "title": raw.get("title"),
        "abstract": raw.get("abstractText"),
        "pub_year": pub_year,
        "author_string": raw.get("authorString"),
        "journal_title": journal_title,
        "first_publication_date": raw.get("firstPublicationDate"),
        "query_search_term": query_term,
        "journal_info_json": json.dumps(journal_info) if journal_info else None,
        "keyword_list_json": json.dumps(raw["keywordList"]) if raw.get("keywordList") else None,
    }


def export_to_csv(df: pd.DataFrame, output_path: Path, exclude_columns: list[str]) -> int:
    """保存 CSV（utf-8-sig），返回行数。"""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    df = df.drop(columns=[c for c in exclude_columns if c in df.columns])
    df.to_csv(output_path, index=False, encoding="utf-8-sig")
    return len(df)


def normalize_value(v) -> str | None:
    """将 pandas NA / 空字符串 / 'N/A' 标准化为 None。"""
    if v is None:
        return None
    try:
        if pd.isna(v):
            return None
    except (TypeError, ValueError):
        pass
    s = str(v).strip()
    if s == "" or s.upper() == "N/A":
        return None
    return s

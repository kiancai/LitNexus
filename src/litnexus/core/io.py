"""JSONL 读写与 CSV 导出辅助模块。"""

from __future__ import annotations

import csv
import datetime
import json
import sqlite3
import sys
from collections.abc import Iterator
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Sequence

    from litnexus.core.fields import FieldSpec


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


def parse_article(raw: dict, extra_fields: Sequence[FieldSpec] = ()) -> dict:
    """将 EPMC API 原始 JSON 映射到 DB schema 字段。

    extra_fields：额外要抓取的可选字段（来自 fields.active_extra_fields）。
    """
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

    record = {
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
    for spec in extra_fields:
        record[spec.id] = spec.extract(raw)
    return record


def export_to_csv(
    columns: Sequence[str],
    rows: Sequence[Sequence],
    output_path: Path,
    exclude_columns: list[str],
) -> int:
    """保存 CSV（utf-8-sig，Excel 可直接打开），返回行数。"""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    keep = [i for i, c in enumerate(columns) if c not in exclude_columns]
    with open(output_path, "w", encoding="utf-8-sig", newline="") as f:
        writer = csv.writer(f)
        writer.writerow([columns[i] for i in keep])
        for row in rows:
            writer.writerow([row[i] for i in keep])
    return len(rows)


def normalize_value(v) -> str | None:
    """将 None / NaN / 空字符串 / 'N/A' 标准化为 None。"""
    if v is None:
        return None
    if isinstance(v, float) and v != v:  # NaN
        return None
    s = str(v).strip()
    if s == "" or s.upper() == "N/A":
        return None
    return s


# ── 复筛 CSV 导回 ─────────────────────────────────────────────────────────────


def import_reviewed_csv(
    conn: sqlite3.Connection,
    csv_path: Path,
    annotation_columns: list[str],
) -> tuple[int, int, int]:
    """从（在 Excel 中编辑过的）CSV 读取复筛标注并写回数据库。

    按 epmc_id（回退 pmid/doi）匹配，只回写 annotation_columns（如 include/tags），
    留空的单元格会被跳过、不会抹掉已有标注。返回 (updated, unmatched, total)。
    """
    from litnexus.core import db as db_mod

    with open(csv_path, encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        header = reader.fieldnames or []
        raw_rows = list(reader)

    total = len(raw_rows)
    if total == 0:
        return 0, 0, 0

    key_cols = [c for c in ("epmc_id", "pmid", "doi") if c in header]
    if not key_cols:
        raise ValueError("CSV 缺少匹配键列（需要 epmc_id / pmid / doi 之一）。")

    ann_cols = [c for c in annotation_columns if c in header]
    if not ann_cols:
        raise ValueError(
            f"CSV 中没有可写回的标注列（期望之一：{', '.join(annotation_columns)}）。"
        )

    rows: list[dict] = []
    for r in raw_rows:
        row: dict = {}
        for k in key_cols:
            v = normalize_value(r.get(k))
            if v is not None:
                row[k] = v
        for c in ann_cols:
            v = normalize_value(r.get(c))
            if c == "include" and v is not None:
                v = v.lower()
            row[c] = v
        rows.append(row)

    updated, unmatched = db_mod.apply_review(conn, rows, annotation_columns)
    return updated, unmatched, total


# ── 文件管理工具 ────────────────────────────────────────────────────────────


def format_file_size(size_bytes: int) -> str:
    """将字节数转换为人类可读的文件大小。"""
    for unit in ("B", "KB", "MB", "GB"):
        if size_bytes < 1024:
            return f"{size_bytes:.1f} {unit}" if unit != "B" else f"{size_bytes} B"
        size_bytes /= 1024
    return f"{size_bytes:.1f} TB"


def list_files(directory: Path, glob: str = "*") -> list[dict]:
    """列出目录下的文件，返回 [{name, path, size, size_str, mtime}]。"""
    if not directory.exists():
        return []
    files = []
    for f in sorted(directory.glob(glob)):
        if f.is_file():
            stat = f.stat()
            files.append({
                "name": f.name,
                "path": str(f),
                "size": stat.st_size,
                "size_str": format_file_size(stat.st_size),
                "mtime": datetime.datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M"),
            })
    return files


def dir_total_size(directory: Path) -> tuple[int, str]:
    """计算目录下所有文件的总大小，返回 (bytes, readable_str)。"""
    if not directory.exists():
        return 0, "0 B"
    total = sum(f.stat().st_size for f in directory.rglob("*") if f.is_file())
    return total, format_file_size(total)


def delete_file(path: Path) -> bool:
    """删除单个文件，返回是否成功。"""
    try:
        path.unlink()
        return True
    except OSError:
        return False

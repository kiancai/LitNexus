"""core/pipeline.py 纯逻辑测试（merge_jsonl / export_articles）。"""

from __future__ import annotations

import csv
import json

import pytest

from litnexus.core import db as db_mod
from litnexus.core import pipeline as pipeline_mod


def _write_jsonl(path, rows):
    path.write_text("\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")


def _read_csv(path):
    with open(path, encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))


# ── merge_jsonl ───────────────────────────────────────────────────────────────


def test_merge_jsonl_inserts_dedups_and_counts_errors(ws_cfg):
    ws, cfg = ws_cfg
    conn = db_mod.get_connection(ws.db_path, cfg)
    d = ws.downloads_dir
    _write_jsonl(d / "a.jsonl", [
        {"id": "E1", "pmid": "1", "title": "T1", "pubYear": "2026"},
        {"id": "E2", "pmid": "2", "title": "T2", "pubYear": "2026"},
    ])
    _write_jsonl(d / "b.jsonl", [
        {"id": "E2", "pmid": "2", "title": "T2 dup"},  # epmc_id 重复 → skipped
        {"pmid": "9", "title": "no id"},               # 缺 id → error
    ])

    r = pipeline_mod.merge_jsonl(conn, cfg, d)

    assert r.files == 2
    assert r.inserted == 2
    assert r.skipped == 1
    assert r.errors == 1
    assert conn.execute("SELECT COUNT(*) FROM articles").fetchone()[0] == 2
    conn.close()


def test_merge_jsonl_extra_fields_ingested(ws_cfg):
    ws, cfg = ws_cfg
    cfg.ingest.extra_fields = ["cited_by_count"]
    conn = db_mod.get_connection(ws.db_path, cfg)  # 建出 cited_by_count 列
    _write_jsonl(ws.downloads_dir / "a.jsonl", [
        {"id": "E1", "pmid": "1", "title": "T1", "pubYear": "2026", "citedByCount": 7},
    ])

    r = pipeline_mod.merge_jsonl(conn, cfg, ws.downloads_dir)

    assert (r.inserted, r.skipped, r.errors) == (1, 0, 0)
    val = conn.execute("SELECT cited_by_count FROM articles WHERE epmc_id='E1'").fetchone()[0]
    assert val == 7
    conn.close()


# ── export_articles ───────────────────────────────────────────────────────────


def test_export_articles_writes_csv_and_drops_excluded(ws_cfg, tmp_path):
    ws, cfg = ws_cfg
    conn = db_mod.get_connection(ws.db_path, cfg)
    db_mod.insert_articles(conn, [
        {"epmc_id": "E1", "pmid": "1", "title": "T1", "pub_year": 2026},
        {"epmc_id": "E2", "pmid": "2", "title": "T2", "pub_year": 2026},
    ])
    out = tmp_path / "out.csv"

    n = pipeline_mod.export_articles(conn, cfg, "all", out)

    assert n == 2 and out.exists()
    rows = _read_csv(out)
    assert {r["epmc_id"] for r in rows} == {"E1", "E2"}
    for c in cfg.export.exclude_columns:
        assert c not in rows[0]  # 排除列已被 drop
    conn.close()


def test_export_articles_empty_returns_zero(ws_cfg, tmp_path):
    ws, cfg = ws_cfg
    conn = db_mod.get_connection(ws.db_path, cfg)
    out = tmp_path / "out.csv"

    n = pipeline_mod.export_articles(conn, cfg, "all", out)

    assert n == 0 and not out.exists()
    conn.close()


def test_export_articles_pending_without_include_raises(ws_cfg, tmp_path):
    ws, cfg = ws_cfg
    cfg.schema_cfg.custom_columns = ["tags"]  # 无 include
    conn = db_mod.get_connection(ws.db_path, cfg)
    db_mod.insert_articles(conn, [{"epmc_id": "E1", "pmid": "1", "title": "T", "pub_year": 2026}])

    with pytest.raises(ValueError):
        pipeline_mod.export_articles(conn, cfg, "pending", tmp_path / "x.csv")
    conn.close()

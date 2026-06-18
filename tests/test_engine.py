from __future__ import annotations

import csv

import pytest
from pydantic import ValidationError

from litnexus.core import db as db_mod
from litnexus.core.config import (
    ConfigError,
    Question,
    SchemaConfig,
    get_api_key,
    get_base_url,
    load_config,
    resolved_ai,
)
from litnexus.core.config_saver import save_config
from litnexus.core.io import export_to_csv, import_reviewed_csv
from litnexus.core.workspace import create_workspace


def _read_csv(path):
    with open(path, encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        return list(reader.fieldnames or []), list(reader)


def _write_csv(path, fieldnames, rows):
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def make_article(epmc_id, pmid=None, doi=None, **extra):
    base = {
        "epmc_id": epmc_id, "pmid": pmid, "doi": doi, "source": "MED", "pmcid": None,
        "title": f"Title {epmc_id}", "abstract": "abstract", "pub_year": 2026,
        "author_string": "Author", "journal_title": "Nature",
        "first_publication_date": "2026-01-01", "query_search_term": "kw",
        "journal_info_json": None, "keyword_list_json": None,
    }
    base.update(extra)
    return base


# ws_cfg fixture 定义在 conftest.py（与 test_ai.py 共享）

# ── 配置 ──────────────────────────────────────────────────────────────────────


def test_config_defaults(ws_cfg):
    _ws, cfg = ws_cfg
    assert [q.id for q in cfg.classify.questions] == ["q1", "q2"]
    assert cfg.schema_cfg.custom_columns == ["include", "tags"]


def test_config_env_override(isolated_state, monkeypatch):
    ws = create_workspace(isolated_state / "ws")
    monkeypatch.setenv("LITNEXUS_API_KEY", "sk-xyz")
    monkeypatch.setenv("LITNEXUS_BASE_URL", "https://env.example/v1")
    cfg = load_config(ws.config_path)
    # 环境变量不再注入持久字段（避免被 save_config 落盘）
    assert cfg.ai.api_key == ""
    # 运行期由 get_api_key / get_base_url / resolved_ai 解析
    assert get_api_key(cfg) == "sk-xyz"
    assert get_base_url(cfg) == "https://env.example/v1"
    ai = resolved_ai(cfg)
    assert ai.api_key == "sk-xyz" and ai.base_url == "https://env.example/v1"
    # resolved_ai 不得修改原 cfg
    assert cfg.ai.api_key == ""


def test_env_key_not_persisted(isolated_state, monkeypatch):
    """回归：仅来自环境变量的密钥不能被 save_config 写入 litnexus.toml。"""
    ws = create_workspace(isolated_state / "ws")
    monkeypatch.setenv("LITNEXUS_API_KEY", "sk-secret")
    cfg = load_config(ws.config_path)
    # 即便运行期解析过 env key（模拟跑了一遍翻译/分类）
    assert resolved_ai(cfg).api_key == "sk-secret"
    # 保存配置后，磁盘上的 api_key 仍应为空
    save_config(cfg, ws.config_path)
    assert load_config(ws.config_path).ai.api_key == ""


# ── 入库 / 去重 ──────────────────────────────────────────────────────────────


def test_dedup_on_pmid(ws_cfg):
    ws, cfg = ws_cfg
    conn = db_mod.get_connection(ws.db_path, cfg)
    ins1, _ = db_mod.insert_articles(conn, [make_article("E1", pmid="1", doi="d1")])
    ins2, skip2 = db_mod.insert_articles(conn, [make_article("E2", pmid="1", doi="d2")])
    assert ins1 == 1
    assert (ins2, skip2) == (0, 1)  # 相同 pmid 被 UNIQUE 约束跳过
    conn.close()


# ── 复筛 CSV 导出 → 导入闭环 ──────────────────────────────────────────────────


def test_review_roundtrip(ws_cfg, tmp_path):
    ws, cfg = ws_cfg
    conn = db_mod.get_connection(ws.db_path, cfg)
    db_mod.insert_articles(
        conn,
        [make_article("E1", pmid="1", doi="d1"), make_article("E2", pmid="2", doi="d2")],
    )
    csv_path = tmp_path / "review.csv"
    columns, db_rows = db_mod.fetch_for_export(conn, "all")
    export_to_csv(columns, db_rows, csv_path, cfg.export.exclude_columns)

    header, rows = _read_csv(csv_path)
    assert "epmc_id" in header  # 没有被 BOM 污染
    for r in rows:
        if r["epmc_id"] == "E1":
            r["include"] = "YES"  # 大小写归一化
            r["tags"] = "priority"
        elif r["epmc_id"] == "E2":
            r["include"] = "no"
    _write_csv(csv_path, header, rows)

    assert import_reviewed_csv(conn, csv_path, cfg.schema_cfg.custom_columns) == (2, 0, 2)
    stats = db_mod.get_stats(conn, cfg.classify.questions)
    assert stats["reviewed_yes"] == 1 and stats["reviewed_no"] == 1
    e1 = dict(conn.execute("SELECT include, tags FROM articles WHERE epmc_id='E1'").fetchone())
    assert e1 == {"include": "yes", "tags": "priority"}

    # 留空的单元格不应抹掉已有标注
    blanked = tmp_path / "blank.csv"
    header2, rows2 = _read_csv(csv_path)
    for r in rows2:
        r["include"] = ""
        r["tags"] = ""
    _write_csv(blanked, header2, rows2)
    import_reviewed_csv(conn, blanked, cfg.schema_cfg.custom_columns)
    e1b = dict(conn.execute("SELECT include, tags FROM articles WHERE epmc_id='E1'").fetchone())
    assert e1b == {"include": "yes", "tags": "priority"}
    conn.close()


def test_import_requires_key_column(ws_cfg, tmp_path):
    ws, cfg = ws_cfg
    conn = db_mod.get_connection(ws.db_path, cfg)
    csv_path = tmp_path / "bad.csv"
    _write_csv(csv_path, ["include"], [{"include": "yes"}])
    with pytest.raises(ValueError):
        import_reviewed_csv(conn, csv_path, cfg.schema_cfg.custom_columns)
    conn.close()


# ── 标识符校验（P1）───────────────────────────────────────────────────────────


def test_question_id_must_be_valid_identifier():
    assert Question(id="q1", text="t").id == "q1"
    for bad in ("bad id", "1q", "q-1", "drop table"):
        with pytest.raises(ValidationError):
            Question(id=bad, text="t")


def test_custom_columns_must_be_valid_identifiers():
    assert SchemaConfig(custom_columns=["include", "tags"]).custom_columns == ["include", "tags"]
    with pytest.raises(ValidationError):
        SchemaConfig(custom_columns=["include", "DROP TABLE"])


def test_load_config_bad_toml_raises_configerror(isolated_state):
    ws = create_workspace(isolated_state / "ws")
    ws.config_path.write_text("[unclosed\n", encoding="utf-8")
    with pytest.raises(ConfigError):
        load_config(ws.config_path)


def test_load_config_invalid_question_id_raises_configerror(isolated_state):
    ws = create_workspace(isolated_state / "ws")
    ws.config_path.write_text(
        '[[classify.questions]]\nid = "bad id"\ntext = "t"\n', encoding="utf-8"
    )
    with pytest.raises(ConfigError):
        load_config(ws.config_path)


# ── 导出 pending 守卫（P1）────────────────────────────────────────────────────


def test_export_pending_without_include_raises(ws_cfg):
    ws, cfg = ws_cfg
    cfg.schema_cfg.custom_columns = ["tags"]  # 去掉 include
    conn = db_mod.get_connection(ws.db_path, cfg)
    with pytest.raises(ValueError):
        db_mod.fetch_for_export(conn, "pending")
    # all 模式不依赖 include，应正常返回
    db_mod.fetch_for_export(conn, "all")
    conn.close()


# ── config_saver 往返（P2）────────────────────────────────────────────────────


def test_config_saver_roundtrip(ws_cfg):
    ws, cfg = ws_cfg
    cfg.download.days = 7
    cfg.translate.batch_size = 50
    cfg.classify.questions = [Question(id="qa", text="text a"), Question(id="qb", text="text b")]
    cfg.schema_cfg.custom_columns = ["include", "tags", "priority"]
    cfg.export.filter = "all"

    save_config(cfg, ws.config_path)
    reloaded = load_config(ws.config_path)

    assert reloaded.download.days == 7
    assert reloaded.translate.batch_size == 50
    assert [q.id for q in reloaded.classify.questions] == ["qa", "qb"]
    assert reloaded.schema_cfg.custom_columns == ["include", "tags", "priority"]
    assert reloaded.export.filter == "all"
    assert reloaded.model_dump() == cfg.model_dump()  # 完整等价


# ── schema 版本查询（P2）──────────────────────────────────────────────────────


def test_get_schema_version_and_columns(ws_cfg):
    ws, cfg = ws_cfg
    conn = db_mod.get_connection(ws.db_path, cfg)
    assert db_mod.get_schema_version(conn) == db_mod.SCHEMA_VERSION
    cols = db_mod.list_columns(conn)
    assert "epmc_id" in cols and "include" in cols and "q1_ans" in cols
    conn.close()


# ── 分类可观测性与重置（P3）───────────────────────────────────────────────────


def test_get_stats_answer_breakdown(ws_cfg):
    ws, cfg = ws_cfg
    conn = db_mod.get_connection(ws.db_path, cfg)
    db_mod.insert_articles(
        conn,
        [make_article(f"E{i}", pmid=str(i), doi=f"d{i}") for i in range(1, 4)],
    )
    conn.execute("UPDATE articles SET q1_ans='是' WHERE epmc_id='E1'")
    conn.execute("UPDATE articles SET q1_ans='否' WHERE epmc_id='E2'")
    conn.execute("UPDATE articles SET q1_ans='API错误' WHERE epmc_id='E3'")
    conn.commit()

    s = db_mod.get_stats(conn, cfg.classify.questions)
    assert s["q1_yes"] == 1
    assert s["q1_no"] == 1
    assert s["q1_other"] == 1  # API错误 / N/A 等非 是/否
    assert s["pending_q1"] == 0
    conn.close()


def test_reset_classification_failed_then_all(ws_cfg):
    ws, cfg = ws_cfg
    conn = db_mod.get_connection(ws.db_path, cfg)
    db_mod.insert_articles(
        conn,
        [make_article("E1", pmid="1", doi="d1"), make_article("E2", pmid="2", doi="d2")],
    )
    conn.execute("UPDATE articles SET q1_ans='是', q1_rea='r' WHERE epmc_id='E1'")
    conn.execute("UPDATE articles SET q1_ans='API错误', q1_rea='boom' WHERE epmc_id='E2'")
    conn.commit()

    # --failed：仅清空旧失败行 E2
    counts = db_mod.reset_classification(conn, cfg.classify.questions, only_failed=True)
    assert counts["q1"] == 1 and counts["q2"] == 0
    assert conn.execute("SELECT q1_ans FROM articles WHERE epmc_id='E2'").fetchone()[0] is None
    assert conn.execute("SELECT q1_ans FROM articles WHERE epmc_id='E1'").fetchone()[0] == "是"

    # --all：把剩余的 E1 也清空
    counts2 = db_mod.reset_classification(conn, cfg.classify.questions, only_failed=False)
    assert counts2["q1"] == 1
    assert conn.execute("SELECT q1_ans FROM articles WHERE epmc_id='E1'").fetchone()[0] is None
    conn.close()

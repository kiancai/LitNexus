"""数据库操作模块。

Schema 版本历史：
  v0 — 旧脚本时代（无 user_version，无 include 小写列）
  v1 — 本次重构（精简列、添加索引、user_version=1）
"""

from __future__ import annotations

import shutil
import sqlite3
import sys
from pathlib import Path
from typing import Iterator

import pandas as pd

SCHEMA_VERSION = 1

# ── Schema ────────────────────────────────────────────────────────────────────

_CREATE_TABLE = """
CREATE TABLE IF NOT EXISTS articles (
    epmc_id                 TEXT PRIMARY KEY,
    pmid                    TEXT,
    doi                     TEXT,
    source                  TEXT,
    title                   TEXT,
    abstract                TEXT,
    pub_year                INTEGER,
    author_string           TEXT,
    journal_title           TEXT,
    first_publication_date  TEXT,
    query_search_term       TEXT,
    author_list_json        TEXT,
    journal_info_json       TEXT,
    full_text_url_list_json TEXT,
    mesh_heading_list_json  TEXT,
    keyword_list_json       TEXT,
    title_zh                TEXT,
    q1_ans                  TEXT,
    q1_rea                  TEXT,
    q2_ans                  TEXT,
    q2_rea                  TEXT,
    tags                    TEXT,
    include                 TEXT,
    CONSTRAINT uq_pmid UNIQUE (pmid),
    CONSTRAINT uq_doi  UNIQUE (doi)
);
"""

_CREATE_INDEXES = """
CREATE INDEX IF NOT EXISTS idx_pub_year ON articles(pub_year);
CREATE INDEX IF NOT EXISTS idx_journal  ON articles(journal_title);
CREATE INDEX IF NOT EXISTS idx_include  ON articles(include);
CREATE INDEX IF NOT EXISTS idx_q2_ans   ON articles(q2_ans);
"""

# ── 连接与迁移 ────────────────────────────────────────────────────────────────

def get_connection(db_path: Path) -> sqlite3.Connection:
    """打开数据库，自动迁移 schema，启用 WAL 模式。"""
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    _run_migrations(conn, db_path)
    return conn


def _get_version(conn: sqlite3.Connection) -> int:
    return conn.execute("PRAGMA user_version").fetchone()[0]


def _set_version(conn: sqlite3.Connection, version: int) -> None:
    conn.execute(f"PRAGMA user_version = {version}")


def _table_exists(conn: sqlite3.Connection) -> bool:
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='articles'"
    ).fetchone()
    return row is not None


def _column_exists(conn: sqlite3.Connection, column: str) -> bool:
    cols = {row[1] for row in conn.execute("PRAGMA table_info(articles)")}
    return column in cols


def _run_migrations(conn: sqlite3.Connection, db_path: Path) -> None:
    version = _get_version(conn)
    if version >= SCHEMA_VERSION:
        return

    if not _table_exists(conn):
        # 全新数据库：直接创建最新 schema
        conn.executescript(_CREATE_TABLE + _CREATE_INDEXES)
        _set_version(conn, SCHEMA_VERSION)
        conn.commit()
        return

    if version == 0:
        _migrate_v0_to_v1(conn, db_path)


def _migrate_v0_to_v1(conn: sqlite3.Connection, db_path: Path) -> None:
    """v0（旧脚本）→ v1：添加 include 小写列、索引。

    保守策略：旧列 Include / abstract_zh 保留不删除。
    """
    print("检测到旧版数据库（v0），正在迁移到 v1...")
    bak_path = db_path.with_suffix(".db.bak")
    shutil.copy2(db_path, bak_path)
    print(f"  已备份到：{bak_path}")

    try:
        with conn:
            if not _column_exists(conn, "include"):
                conn.execute("ALTER TABLE articles ADD COLUMN include TEXT")
            if _column_exists(conn, "Include"):
                conn.execute("UPDATE articles SET include = Include WHERE include IS NULL")
            conn.executescript(_CREATE_INDEXES)
            _set_version(conn, 1)
        print("  迁移完成（v0 → v1）。旧列 Include/abstract_zh 已保留，可手动 DROP。")
    except Exception as e:
        print(f"  迁移失败：{e}", file=sys.stderr)
        raise


def run_migrations(conn: sqlite3.Connection, db_path: Path) -> None:
    """供 CLI `db migrate` 命令手动触发。"""
    _run_migrations(conn, db_path)


# ── 文章插入 ──────────────────────────────────────────────────────────────────

_INSERT_SQL = """
INSERT OR IGNORE INTO articles (
    epmc_id, pmid, doi, source,
    title, abstract, pub_year, author_string, journal_title,
    first_publication_date, query_search_term,
    author_list_json, journal_info_json, full_text_url_list_json,
    mesh_heading_list_json, keyword_list_json
) VALUES (
    :epmc_id, :pmid, :doi, :source,
    :title, :abstract, :pub_year, :author_string, :journal_title,
    :first_publication_date, :query_search_term,
    :author_list_json, :journal_info_json, :full_text_url_list_json,
    :mesh_heading_list_json, :keyword_list_json
)
"""


def insert_articles(conn: sqlite3.Connection, articles: list[dict]) -> tuple[int, int]:
    """批量插入（INSERT OR IGNORE），返回 (inserted, skipped)。"""
    cursor = conn.cursor()
    inserted = skipped = 0
    for art in articles:
        cursor.execute(_INSERT_SQL, art)
        if cursor.rowcount > 0:
            inserted += 1
        else:
            skipped += 1
    conn.commit()
    return inserted, skipped


# ── 翻译查询 ──────────────────────────────────────────────────────────────────

def fetch_pending_translations(conn: sqlite3.Connection) -> list[tuple[str, str]]:
    """返回 [(epmc_id, title)] —— title 存在但 title_zh 为 NULL。"""
    rows = conn.execute(
        "SELECT epmc_id, title FROM articles WHERE title IS NOT NULL AND title_zh IS NULL"
    ).fetchall()
    return [(r["epmc_id"], r["title"]) for r in rows]


def update_translations(
    conn: sqlite3.Connection, updates: list[tuple[str, str | None]]
) -> None:
    """批量更新 title_zh，updates 为 [(epmc_id, title_zh)]。"""
    conn.executemany(
        "UPDATE articles SET title_zh = COALESCE(?, title_zh) WHERE epmc_id = ?",
        [(title_zh, epmc_id) for epmc_id, title_zh in updates],
    )
    conn.commit()


# ── 导出与分类回写 ────────────────────────────────────────────────────────────

def fetch_for_export(conn: sqlite3.Connection, filter_mode: str) -> pd.DataFrame:
    """按 filter_mode 导出文章 DataFrame。

    filter_mode:
      "pending" — include IS NULL
      "all"     — 全部
      其他      — 作为 SQL WHERE 子句
    """
    if filter_mode == "pending":
        where = "include IS NULL"
    elif filter_mode == "all":
        where = "1=1"
    else:
        where = filter_mode
    return pd.read_sql_query(
        f"SELECT * FROM articles WHERE {where} ORDER BY pub_year DESC", conn
    )


def update_classifications(conn: sqlite3.Connection, updates: list[dict]) -> int:
    """批量写回 tags/include/q1/q2（COALESCE 保护已有值），返回更新行数。"""
    sql = """
    UPDATE articles SET
        tags    = COALESCE(:tags,    tags),
        include = COALESCE(:include, include),
        q1_ans  = COALESCE(:q1_ans,  q1_ans),
        q1_rea  = COALESCE(:q1_rea,  q1_rea),
        q2_ans  = COALESCE(:q2_ans,  q2_ans),
        q2_rea  = COALESCE(:q2_rea,  q2_rea)
    WHERE epmc_id = :epmc_id
    """
    cursor = conn.cursor()
    total = 0
    for row in updates:
        cursor.execute(sql, {
            "epmc_id": row.get("epmc_id"),
            "tags":    row.get("tags"),
            "include": row.get("include"),
            "q1_ans":  row.get("q1_ans"),
            "q1_rea":  row.get("q1_rea"),
            "q2_ans":  row.get("q2_ans"),
            "q2_rea":  row.get("q2_rea"),
        })
        total += cursor.rowcount
    conn.commit()
    return total


# ── 统计与维护 ────────────────────────────────────────────────────────────────

def get_stats(conn: sqlite3.Connection) -> dict[str, int]:
    """返回数据库统计摘要。"""
    return {
        "total": conn.execute("SELECT COUNT(*) FROM articles").fetchone()[0],
        "pending_translation": conn.execute(
            "SELECT COUNT(*) FROM articles WHERE title IS NOT NULL AND title_zh IS NULL"
        ).fetchone()[0],
        "pending_classification": conn.execute(
            "SELECT COUNT(*) FROM articles WHERE q1_ans IS NULL"
        ).fetchone()[0],
        "reviewed_yes": conn.execute(
            "SELECT COUNT(*) FROM articles WHERE include = 'yes'"
        ).fetchone()[0],
        "reviewed_no": conn.execute(
            "SELECT COUNT(*) FROM articles WHERE include = 'no'"
        ).fetchone()[0],
    }


def backup(db_path: Path) -> Path:
    """备份数据库到 .db.bak，返回备份路径。"""
    bak_path = db_path.with_suffix(".db.bak")
    shutil.copy2(db_path, bak_path)
    return bak_path


def iter_jsonl_files(directory: Path) -> Iterator[Path]:
    """遍历目录下所有 .jsonl 文件，按文件名排序。"""
    return iter(sorted(directory.glob("*.jsonl")))

"""数据库操作模块。

Schema 版本历史：
  v0 — 旧脚本时代（无 user_version，Include 大写，含 3 个大型 JSON 列）
  v1 — 第一次重构（有 bug，已废弃，通过 v2 迁移覆盖）
  v2 — 当前版本：精简列（删 author_list/mesh/fulltext JSON），加回 pmcid/abstract_zh，
        动态问题列（{id}_ans/{id}_rea）和自定义列由 ensure_dynamic_columns() 管理
"""

from __future__ import annotations

import shutil
import sqlite3
import sys
from pathlib import Path
from typing import TYPE_CHECKING, Iterator

if TYPE_CHECKING:
    import pandas as pd
    from litnexus.core.config import Config, Question

SCHEMA_VERSION = 2

# 基础列（不含动态的问题列和自定义列）
_BASE_COLS = (
    "epmc_id", "pmid", "doi", "source", "pmcid",
    "title", "abstract", "pub_year", "author_string",
    "journal_title", "first_publication_date", "query_search_term",
    "journal_info_json", "keyword_list_json",
    "title_zh", "abstract_zh",
)

# ── Schema ────────────────────────────────────────────────────────────────────

_CREATE_TABLE = """
CREATE TABLE IF NOT EXISTS articles (
    epmc_id                TEXT PRIMARY KEY,
    pmid                   TEXT,
    doi                    TEXT,
    source                 TEXT,
    pmcid                  TEXT,
    title                  TEXT,
    abstract               TEXT,
    pub_year               INTEGER,
    author_string          TEXT,
    journal_title          TEXT,
    first_publication_date TEXT,
    query_search_term      TEXT,
    journal_info_json      TEXT,
    keyword_list_json      TEXT,
    title_zh               TEXT,
    abstract_zh            TEXT,
    CONSTRAINT uq_pmid UNIQUE (pmid),
    CONSTRAINT uq_doi  UNIQUE (doi)
);
"""

_CREATE_INDEXES = """
CREATE INDEX IF NOT EXISTS idx_pub_year ON articles(pub_year);
CREATE INDEX IF NOT EXISTS idx_journal  ON articles(journal_title);
"""

# ── 连接 ──────────────────────────────────────────────────────────────────────

def get_connection(db_path: Path, cfg: "Config | None" = None) -> sqlite3.Connection:
    """打开数据库，自动迁移 schema，启用 WAL 模式。

    若传入 cfg，同时调用 ensure_dynamic_columns() 确保问题列和自定义列存在。
    """
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    _run_migrations(conn, db_path)
    if cfg is not None:
        ensure_dynamic_columns(conn, cfg.classify.questions, cfg.schema_cfg.custom_columns)
    return conn


def ensure_dynamic_columns(
    conn: sqlite3.Connection,
    questions: "list[Question]",
    custom_cols: list[str],
) -> None:
    """确保所有配置中定义的问题列和自定义列存在于数据库中。

    若列不存在则自动 ALTER TABLE ADD COLUMN（TEXT 类型）。
    同时为 include 列和问题答案列创建索引（如果存在）。
    """
    existing = {row[1] for row in conn.execute("PRAGMA table_info(articles)")}
    added = []

    for q in questions:
        for suffix in ("_ans", "_rea"):
            col = f"{q.id}{suffix}"
            if col not in existing:
                conn.execute(f"ALTER TABLE articles ADD COLUMN {col} TEXT")
                added.append(col)

    for col in custom_cols:
        if col not in existing:
            conn.execute(f"ALTER TABLE articles ADD COLUMN {col} TEXT")
            added.append(col)

    if added:
        conn.commit()

    # 为常用过滤列建索引
    all_cols = existing | set(added)
    if "include" in all_cols:
        conn.execute("CREATE INDEX IF NOT EXISTS idx_include ON articles(include)")
    for q in questions:
        ans_col = f"{q.id}_ans"
        if ans_col in all_cols:
            conn.execute(
                f"CREATE INDEX IF NOT EXISTS idx_{q.id}_ans ON articles({ans_col})"
            )


# ── 迁移 ──────────────────────────────────────────────────────────────────────

def _get_version(conn: sqlite3.Connection) -> int:
    return conn.execute("PRAGMA user_version").fetchone()[0]


def _set_version(conn: sqlite3.Connection, version: int) -> None:
    conn.execute(f"PRAGMA user_version = {version}")


def _table_exists(conn: sqlite3.Connection) -> bool:
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='articles'"
    ).fetchone()
    return row is not None


def _run_migrations(conn: sqlite3.Connection, db_path: Path) -> None:
    version = _get_version(conn)
    if version >= SCHEMA_VERSION:
        return

    if not _table_exists(conn):
        # 全新数据库：直接建最新 schema
        conn.executescript(_CREATE_TABLE + _CREATE_INDEXES)
        _set_version(conn, SCHEMA_VERSION)
        conn.commit()
        return

    # v0 或 v1 → v2
    _migrate_any_to_v2(conn, db_path)


def _migrate_any_to_v2(conn: sqlite3.Connection, db_path: Path) -> None:
    """将 v0 或 v1 数据库迁移到 v2。

    操作：
    - 删除 author_list_json / mesh_heading_list_json / full_text_url_list_json
    - 加回 pmcid / abstract_zh
    - Include（大写）→ include（小写）
    - 动态列（q1_ans/q1_rea/q2_ans/q2_rea/include/tags 等）数据保留
    """
    version = _get_version(conn)
    print(f"检测到 v{version} 数据库，正在迁移到 v2...")
    bak = db_path.with_suffix(".db.bak")
    shutil.copy2(db_path, bak)
    print(f"  已备份到：{bak}")

    old_cols = {row[1] for row in conn.execute("PRAGMA table_info(articles)")}

    try:
        with conn:
            # 1. 建新表（临时名）
            conn.execute("""
                CREATE TABLE articles_v2 (
                    epmc_id                TEXT PRIMARY KEY,
                    pmid                   TEXT,
                    doi                    TEXT,
                    source                 TEXT,
                    pmcid                  TEXT,
                    title                  TEXT,
                    abstract               TEXT,
                    pub_year               INTEGER,
                    author_string          TEXT,
                    journal_title          TEXT,
                    first_publication_date TEXT,
                    query_search_term      TEXT,
                    journal_info_json      TEXT,
                    keyword_list_json      TEXT,
                    title_zh               TEXT,
                    abstract_zh            TEXT,
                    CONSTRAINT uq_pmid UNIQUE (pmid),
                    CONSTRAINT uq_doi  UNIQUE (doi)
                )
            """)

            # 2. 复制基础列（旧表中没有的列用 NULL 填充）
            src_exprs = [col if col in old_cols else "NULL" for col in _BASE_COLS]
            conn.execute(
                f"INSERT OR IGNORE INTO articles_v2 ({', '.join(_BASE_COLS)}) "
                f"SELECT {', '.join(src_exprs)} FROM articles"
            )

            # 3. 复制动态列（如果旧表中存在）
            dynamic_map: list[tuple[str, str]] = []  # (new_col, old_col)
            # include / Include
            if "include" in old_cols:
                dynamic_map.append(("include", "include"))
            elif "Include" in old_cols:
                dynamic_map.append(("include", "Include"))
            # 其他标准动态列
            for col in ("tags", "q1_ans", "q1_rea", "q2_ans", "q2_rea"):
                if col in old_cols:
                    dynamic_map.append((col, col))
            # 还可能有其他自定义列（跳过已知的 EPMC 列和已处理的）
            known = set(_BASE_COLS) | {
                "author_list_json", "mesh_heading_list_json", "full_text_url_list_json",
                "Include", "include", "tags", "q1_ans", "q1_rea", "q2_ans", "q2_rea",
                "abstract_zh",
            }
            for col in old_cols:
                if col not in known:
                    dynamic_map.append((col, col))

            for new_col, old_col in dynamic_map:
                conn.execute(f"ALTER TABLE articles_v2 ADD COLUMN {new_col} TEXT")
                conn.execute(
                    f"UPDATE articles_v2 SET {new_col} = "
                    f"(SELECT {old_col} FROM articles "
                    f"WHERE articles.epmc_id = articles_v2.epmc_id)"
                )

            # 4. 换表
            conn.execute("DROP TABLE articles")
            conn.execute("ALTER TABLE articles_v2 RENAME TO articles")

            # 5. 重建索引
            conn.executescript(_CREATE_INDEXES)
            _set_version(conn, 2)

        print(f"  迁移完成（v{version} → v2）。")
        print("  已删除 author_list_json / mesh_heading_list_json / full_text_url_list_json。")
        print("  建议之后运行 python tools/migrate_personal_db.py 执行 VACUUM 压缩空间。")
    except Exception as e:
        print(f"  迁移失败：{e}", file=sys.stderr)
        raise


def run_migrations(conn: sqlite3.Connection, db_path: Path) -> None:
    """供 CLI `db migrate` 命令手动触发。"""
    _run_migrations(conn, db_path)


# ── 文章插入 ──────────────────────────────────────────────────────────────────

_INSERT_SQL = """
INSERT OR IGNORE INTO articles (
    epmc_id, pmid, doi, source, pmcid,
    title, abstract, pub_year, author_string, journal_title,
    first_publication_date, query_search_term,
    journal_info_json, keyword_list_json
) VALUES (
    :epmc_id, :pmid, :doi, :source, :pmcid,
    :title, :abstract, :pub_year, :author_string, :journal_title,
    :first_publication_date, :query_search_term,
    :journal_info_json, :keyword_list_json
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


# ── 分类查询（直接 DB 模式）──────────────────────────────────────────────────

def fetch_pending_classification(
    conn: sqlite3.Connection,
    questions: "list[Question]",
) -> list[dict]:
    """返回需要分类的文章列表。

    文章需满足：至少一个问题的 _ans 列为 NULL，且 title 或 abstract 不为空。
    """
    if not questions:
        return []
    null_checks = " OR ".join(f"{q.id}_ans IS NULL" for q in questions)
    rows = conn.execute(
        f"SELECT epmc_id, title, abstract FROM articles "
        f"WHERE ({null_checks}) AND (title IS NOT NULL OR abstract IS NOT NULL)"
    ).fetchall()
    return [dict(r) for r in rows]


# ── 导出 ──────────────────────────────────────────────────────────────────────

def fetch_for_export(conn: sqlite3.Connection, filter_mode: str) -> "pd.DataFrame":
    """按 filter_mode 导出文章 DataFrame。

    filter_mode:
      "pending" — include IS NULL（需 include 列存在）
      "all"     — 全部
      其他      — 作为 SQL WHERE 子句
    """
    import pandas as pd  # 懒导入，仅导出时需要
    if filter_mode == "pending":
        where = "include IS NULL"
    elif filter_mode == "all":
        where = "1=1"
    else:
        where = filter_mode
    return pd.read_sql_query(
        f"SELECT * FROM articles WHERE {where} ORDER BY pub_year DESC", conn
    )


# ── 统计与维护 ────────────────────────────────────────────────────────────────

def get_stats(
    conn: sqlite3.Connection,
    questions: "list[Question] | None" = None,
) -> dict[str, int]:
    """返回数据库统计摘要。questions 不为空时统计各问题的待处理数。"""
    stats: dict[str, int] = {
        "total": conn.execute("SELECT COUNT(*) FROM articles").fetchone()[0],
        "pending_translation": conn.execute(
            "SELECT COUNT(*) FROM articles WHERE title IS NOT NULL AND title_zh IS NULL"
        ).fetchone()[0],
    }

    existing_cols = {row[1] for row in conn.execute("PRAGMA table_info(articles)")}

    if questions:
        for q in questions:
            col = f"{q.id}_ans"
            if col in existing_cols:
                stats[f"pending_{q.id}"] = conn.execute(
                    f"SELECT COUNT(*) FROM articles WHERE {col} IS NULL"
                ).fetchone()[0]

    if "include" in existing_cols:
        stats["reviewed_yes"] = conn.execute(
            "SELECT COUNT(*) FROM articles WHERE include = 'yes'"
        ).fetchone()[0]
        stats["reviewed_no"] = conn.execute(
            "SELECT COUNT(*) FROM articles WHERE include = 'no'"
        ).fetchone()[0]

    return stats


def backup(db_path: Path) -> Path:
    """备份数据库到 .db.bak，返回备份路径。"""
    bak_path = db_path.with_suffix(".db.bak")
    shutil.copy2(db_path, bak_path)
    return bak_path


def iter_jsonl_files(directory: Path) -> Iterator[Path]:
    """遍历目录下所有 .jsonl 文件，按文件名排序。"""
    return iter(sorted(directory.glob("*.jsonl")))

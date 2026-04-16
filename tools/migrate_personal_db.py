#!/usr/bin/env python3
"""个人数据库迁移脚本（一次性使用，纯 stdlib，无需安装包）。

用途：将旧版（v0/v1）数据库迁移到 v2 schema，并执行 VACUUM 回收空间。

使用方法：
    python3 tools/migrate_personal_db.py /path/to/epmc_articles.db

迁移内容：
  - 删除 author_list_json / mesh_heading_list_json / full_text_url_list_json
  - 加回 pmcid / abstract_zh（旧库中本来就有，直接保留）
  - Include（大写）→ include（小写），数据保留
  - 保留 q1_ans / q1_rea / q2_ans / q2_rea / tags 等已有数据
  - VACUUM 压缩空间
"""

import shutil
import sqlite3
import sys
from pathlib import Path

SCHEMA_VERSION = 2

_BASE_COLS = (
    "epmc_id", "pmid", "doi", "source", "pmcid",
    "title", "abstract", "pub_year", "author_string",
    "journal_title", "first_publication_date", "query_search_term",
    "journal_info_json", "keyword_list_json",
    "title_zh", "abstract_zh",
)

# 已知的、需要从旧库删除（不复制到新库）的列
_DROP_COLS = {"author_list_json", "mesh_heading_list_json", "full_text_url_list_json"}


def get_col_names(conn: sqlite3.Connection) -> set[str]:
    return {row[1] for row in conn.execute("PRAGMA table_info(articles)")}


def print_stats(db_path: Path, label: str) -> None:
    size_mb = db_path.stat().st_size / 1024 / 1024
    conn = sqlite3.connect(db_path)
    try:
        count = conn.execute("SELECT COUNT(*) FROM articles").fetchone()[0]
        version = conn.execute("PRAGMA user_version").fetchone()[0]
        cols = [row[1] for row in conn.execute("PRAGMA table_info(articles)")]
    finally:
        conn.close()
    print(f"\n[{label}]")
    print(f"  schema 版本：v{version}")
    print(f"  文章总数：   {count}")
    print(f"  文件大小：   {size_mb:.1f} MB")
    print(f"  列数：       {len(cols)}")
    print(f"  列列表：     {', '.join(cols)}")


def migrate(db_path: Path) -> None:
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode=WAL")

    version = conn.execute("PRAGMA user_version").fetchone()[0]
    if version >= SCHEMA_VERSION:
        print(f"数据库已是 v{version}，无需迁移。")
        conn.close()
        return

    old_cols = get_col_names(conn)

    print(f"\n正在从 v{version} 迁移到 v{SCHEMA_VERSION}...")

    with conn:
        # 1. 建新表
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

        # 2. 复制基础列（旧表缺的列用 NULL 代替）
        src_exprs = [col if col in old_cols else "NULL" for col in _BASE_COLS]
        conn.execute(
            f"INSERT OR IGNORE INTO articles_v2 ({', '.join(_BASE_COLS)}) "
            f"SELECT {', '.join(src_exprs)} FROM articles"
        )

        # 3. 复制动态列
        dynamic_map: list[tuple[str, str]] = []  # (new_col, old_col)
        if "include" in old_cols:
            dynamic_map.append(("include", "include"))
        elif "Include" in old_cols:
            dynamic_map.append(("include", "Include"))

        for col in ("tags", "q1_ans", "q1_rea", "q2_ans", "q2_rea"):
            if col in old_cols:
                dynamic_map.append((col, col))

        # 其余未知自定义列（跳过要删除的和已处理的）
        known = set(_BASE_COLS) | _DROP_COLS | {
            "Include", "include", "tags",
            "q1_ans", "q1_rea", "q2_ans", "q2_rea",
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
            print(f"  已复制列：{old_col} → {new_col}")

        # 4. 换表
        conn.execute("DROP TABLE articles")
        conn.execute("ALTER TABLE articles_v2 RENAME TO articles")

        # 5. 重建索引
        conn.execute("CREATE INDEX IF NOT EXISTS idx_pub_year ON articles(pub_year)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_journal  ON articles(journal_title)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_include  ON articles(include)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_q1_ans   ON articles(q1_ans)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_q2_ans   ON articles(q2_ans)")
        conn.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")

    conn.close()
    print(f"Schema 迁移完成（v{version} → v{SCHEMA_VERSION}）。")


def main() -> None:
    if len(sys.argv) < 2:
        print("用法：python3 tools/migrate_personal_db.py /path/to/epmc_articles.db")
        sys.exit(1)

    db_path = Path(sys.argv[1]).expanduser()
    if not db_path.exists():
        print(f"数据库不存在：{db_path}")
        sys.exit(1)

    print(f"目标数据库：{db_path}")
    print_stats(db_path, "迁移前")

    # 备份
    bak = db_path.with_suffix(".db.bak")
    print(f"\n正在备份到：{bak}")
    shutil.copy2(db_path, bak)
    print("备份完成。")

    # 迁移
    migrate(db_path)

    # VACUUM
    print("\n正在执行 VACUUM（回收删除列的磁盘空间，可能需要数分钟）...")
    conn = sqlite3.connect(db_path)
    try:
        conn.execute("VACUUM")
        conn.commit()
    finally:
        conn.close()
    print("VACUUM 完成。")

    print_stats(db_path, "迁移后")
    print(f"\n备份文件：{bak}")
    print("确认数据无误后可手动删除备份。")


if __name__ == "__main__":
    main()

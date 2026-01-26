import sqlite3
import pandas as pd
import sys
from pathlib import Path

# 配置
DATABASE_FILENAME = "../database/epmc_articles.db"
# INPUT_CSV = "../database/exported_articles.csv"
INPUT_CSV = "../database/exported_articles_analyzed.csv"

COLUMNS_TO_UPDATE = [
    "tags",
    "Include",
    "q1_ans",
    "q1_rea",
    "q2_ans",
    "q2_rea",
]


def ensure_columns(conn: sqlite3.Connection):
    cursor = conn.cursor()
    cursor.execute("PRAGMA table_info(articles)")
    existing = {row[1] for row in cursor.fetchall()}
    added = []
    for col in COLUMNS_TO_UPDATE:
        if col not in existing:
            cursor.execute(f"ALTER TABLE articles ADD COLUMN {col} TEXT")
            added.append(col)
    if added:
        conn.commit()
        print(f"已添加缺失列: {', '.join(added)}")


def normalize(v):
    if v is None or pd.isna(v):
        return None
    s = str(v).strip()
    if s == "" or s.upper() == "N/A":
        return None
    return s


def main():
    db_path = Path(DATABASE_FILENAME)
    csv_path = Path(INPUT_CSV)

    if not csv_path.exists():
        print(f"错误: 未找到 CSV 文件: {INPUT_CSV}", file=sys.stderr)
        sys.exit(1)
    if not db_path.exists():
        print(f"错误: 未找到数据库文件: {DATABASE_FILENAME}", file=sys.stderr)
        sys.exit(1)

    try:
        df = pd.read_csv(csv_path)
    except Exception as e:
        print(f"读取 CSV 失败: {e}", file=sys.stderr)
        sys.exit(1)

    if "epmc_id" not in df.columns:
        print("错误: CSV 中缺少 'epmc_id' 列。", file=sys.stderr)
        sys.exit(1)

    missing_cols = [c for c in COLUMNS_TO_UPDATE if c not in df.columns]
    if missing_cols:
        print(f"错误: CSV 缺少列: {', '.join(missing_cols)}", file=sys.stderr)
        sys.exit(1)

    try:
        conn = sqlite3.connect(db_path)
    except sqlite3.Error as e:
        print(f"数据库连接失败: {e}", file=sys.stderr)
        sys.exit(1)

    try:
        ensure_columns(conn)

        cursor = conn.cursor()
        sql = (
            "UPDATE articles SET "
            "tags = COALESCE(?, tags), "
            "Include = COALESCE(?, Include), "
            "q1_ans = COALESCE(?, q1_ans), "
            "q1_rea = COALESCE(?, q1_rea), "
            "q2_ans = COALESCE(?, q2_ans), "
            "q2_rea = COALESCE(?, q2_rea) "
            "WHERE epmc_id = ?"
        )

        params = []
        total = len(df)
        for _, row in df.iterrows():
            epmc_id = normalize(row.get("epmc_id"))
            if not epmc_id:
                continue
            values = [normalize(row.get(c)) for c in COLUMNS_TO_UPDATE]
            params.append(tuple(values + [epmc_id]))

        updated_rows = 0
        for p in params:
            cursor.execute(sql, p)
            updated_rows += cursor.rowcount

        conn.commit()
        print(f"处理完成: 输入 {total} 行，成功更新 {updated_rows} 行。")
    except sqlite3.Error as e:
        print(f"数据库更新失败: {e}", file=sys.stderr)
        sys.exit(1)
    finally:
        conn.close()
        print("数据库连接已关闭。")


if __name__ == "__main__":
    main()
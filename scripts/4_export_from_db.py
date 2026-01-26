import sqlite3
import pandas as pd
import sys
from pathlib import Path

# --- 1. 配置 ---

# 数据库文件名（与 2_merge_to_db.py 脚本中一致）
DATABASE_FILENAME = "../database/epmc_articles.db"

# 导出的 CSV 文件名
OUTPUT_CSV_FILENAME = "../database/exported_articles.csv"

# --- 2. 设置筛选条件 (SQL 查询) ---
#### 导出全部文章
# SQL_QUERY = """
# SELECT * FROM articles 
# ORDER BY pub_year DESC;
# """
####  导出 Include 为 NULL/yes 的行
####  IS NULL  /  LIKE 'yes'
SQL_QUERY = """
SELECT * FROM articles 
WHERE Include IS NULL
ORDER BY pub_year DESC;
"""
# ---


def export_db_to_csv():
    """
    连接到 SQLite 数据库, 执行 SQL 查询, 并将结果保存为 CSV.
    """
    print(f"--- 开始从 SQLite 导出到 CSV ---")
    
    db_path = Path(DATABASE_FILENAME)
    if not db_path.exists():
        print(f"!! 错误: 数据库文件未找到: {DATABASE_FILENAME}", file=sys.stderr)
        sys.exit(1)

    conn = None
    try:
        # 1. 连接到数据库
        print(f"正在连接到数据库: {db_path}")
        conn = sqlite3.connect(db_path)
        
        # 2. 执行查询并将结果读入 pandas DataFrame
        print(f"正在执行查询...\n{SQL_QUERY}")
        # pandas 的 read_sql_query 功能非常强大, 自动处理所有数据
        df = pd.read_sql_query(SQL_QUERY, conn)
        
        # 在导出前删除体积较大的 JSON 列，减小 CSV 体积
        excluded_cols = [
            "author_list_json",
            "journal_info_json",
            "full_text_url_list_json",
            "mesh_heading_list_json",
            "keyword_list_json",
        ]
        df = df.drop(columns=excluded_cols, errors="ignore")
        
        print(f"查询完成，找到 {len(df)} 条匹配的文章。")

        if df.empty:
            print("!! 警告: 查询结果为空, 未创建 CSV 文件。")
        else:
            # 3. 将 DataFrame 保存为 CSV
            #    index=False - 不要在 CSV 中包含 pandas 的行索引 (0, 1, 2...)
            #    encoding='utf-8-sig' - 确保 Excel 能正确读取 UTF-8 编码
            print(f"正在保存结果到: {OUTPUT_CSV_FILENAME}")
            df.to_csv(OUTPUT_CSV_FILENAME, index=False, encoding='utf-8-sig')
            print(f"✅ 成功! {len(df)} 条文章已导出到 {OUTPUT_CSV_FILENAME}")

    except sqlite3.Error as e:
        print(f"!! 数据库错误: {e}", file=sys.stderr)
    except pd.errors.DatabaseError as e:
        print(f"!! Pandas/SQL 错误 (请检查你的 SQL_QUERY 语法): {e}", file=sys.stderr)
    except Exception as e:
        print(f"!! 发生意外错误: {e}", file=sys.stderr)
    finally:
        # 4. 关闭数据库连接
        if conn:
            conn.close()
            print("数据库连接已关闭。")

if __name__ == "__main__":
    export_db_to_csv()
import sqlite3
import json
from pathlib import Path
import sys

# --- 1. 配置 ---

# 数据库文件名
DATABASE_FILENAME = "../database/epmc_articles.db"

# 包含 .jsonl 文件的目录
# 请将其更改为你存储 epmc_download_keywords_...jsonl 文件的实际路径
JSONL_DIRECTORY = "../download/"

# --- 2. 数据库表结构 (Schema) ---
# 我们将创建一个名为 'articles' 的表
SCHEMA = """
CREATE TABLE IF NOT EXISTS articles (
    epmc_id TEXT PRIMARY KEY,    -- Europe PMC ID，用作主键
    pmid TEXT,                   -- PubMed ID
    doi TEXT,                    -- DOI
    source TEXT,                 -- 来源 (e.g., "MED", "PPR")
    pmcid TEXT,                  -- PubMed Central ID
    title TEXT,                  -- 标题
    abstract TEXT,               -- 摘要
    pub_year INTEGER,            -- 出版年份
    author_string TEXT,          -- 作者字符串
    journal_title TEXT,          -- 期刊名称
    first_publication_date TEXT, -- 首次发布日期
    query_search_term TEXT,      -- 用于找到该文章的搜索词
    
    -- 将复杂的 JSON 对象/列表 存储为 TEXT
    author_list_json TEXT,
    journal_info_json TEXT,
    full_text_url_list_json TEXT,
    mesh_heading_list_json TEXT,
    keyword_list_json TEXT,

    -- 中文翻译列（供后续脚本使用）
    title_zh TEXT,
    abstract_zh TEXT,

    -- 自定义管理列
    tags TEXT,
    Include TEXT,
    q1_ans TEXT,
    q1_rea TEXT,
    q2_ans TEXT,
    q2_rea TEXT,

    -- 添加唯一约束以帮助去重
    CONSTRAINT pmid_unique UNIQUE (pmid),
    CONSTRAINT doi_unique UNIQUE (doi)
);
"""

def ensure_optional_columns(conn: sqlite3.Connection):
    """
    确保 articles 表包含可选列（title_zh、abstract_zh、tags、Include）。
    """
    print("正在检查并添加可选列（如需）...")
    try:
        cursor = conn.cursor()
        cursor.execute("PRAGMA table_info(articles)")
        existing = {row[1] for row in cursor.fetchall()}
        desired = [
            ("title_zh", "TEXT"),
            ("abstract_zh", "TEXT"),
            ("tags", "TEXT"),
            ("Include", "TEXT"),
        ]
        added_any = False
        for name, type_ in desired:
            if name not in existing:
                cursor.execute(f"ALTER TABLE articles ADD COLUMN {name} {type_}")
                added_any = True
        if added_any:
            conn.commit()
            print("已添加缺失的可选列。")
        else:
            print("所有可选列已存在，无需更新。")
    except sqlite3.Error as e:
        print(f"!! 添加可选列时发生数据库错误: {e}", file=sys.stderr)

def setup_database(db_path: str) -> sqlite3.Connection:
    """
    连接到 SQLite 数据库并创建表（如果不存在）。
    """
    print(f"正在连接到数据库: {db_path}")
    conn = None
    try:
        conn = sqlite3.connect(db_path)
        cursor = conn.cursor()
        cursor.execute(SCHEMA)
        conn.commit()
        # 确保可选列存在（即使表已存在）
        ensure_optional_columns(conn)
        print("数据库表 'articles' 已准备就绪。")
        return conn
    except sqlite3.Error as e:
        print(f"!! 数据库错误: {e}", file=sys.stderr)
        if conn:
            conn.close()
        sys.exit(1) # 严重错误，退出

def process_jsonl_file(filepath: Path, conn: sqlite3.Connection) -> tuple:
    """
    处理单个 .jsonl 文件并将其内容插入数据库。
    """
    print(f"\n--- 正在处理文件: {filepath.name} ---")
    cursor = conn.cursor()
    
    inserted_count = 0
    skipped_count = 0
    error_count = 0
    
    with open(filepath, 'r', encoding='utf-8') as f:
        for i, line in enumerate(f):
            line = line.strip()
            if not line:
                continue

            try:
                article = json.loads(line)
            except json.JSONDecodeError:
                print(f"  !! 警告: 第 {i+1} 行 JSON 格式错误，已跳过。", file=sys.stderr)
                error_count += 1
                continue

            # --- 提取数据 ---
            epmc_id = article.get('id')
            if not epmc_id:
                print(f"  !! 警告: 第 {i+1} 行缺少 'id'，已跳过。", file=sys.stderr)
                error_count += 1
                continue
            
            pmid = article.get('pmid')
            doi = article.get('doi')
            
            # 为了防止 pmid/doi 为空字符串 "" 导致违反唯一约束
            pmid = pmid if pmid else None
            doi = doi if doi else None

            pub_year_str = article.get('pubYear')
            pub_year = None
            if pub_year_str and pub_year_str.isdigit():
                pub_year = int(pub_year_str)

            journal_info = article.get('journalInfo', {})
            journal_title = None
            if journal_info and 'journal' in journal_info and 'title' in journal_info['journal']:
                journal_title = journal_info['journal']['title']

            # 准备要插入的数据元组
            data_tuple = (
                epmc_id,
                pmid,
                doi,
                article.get('source'),
                article.get('pmcid'),
                article.get('title'),
                article.get('abstractText'),
                pub_year,
                article.get('authorString'),
                journal_title,
                article.get('firstPublicationDate'),
                article.get('query_search_term'),
                json.dumps(article.get('authorList')) if article.get('authorList') else None,
                json.dumps(journal_info) if journal_info else None,
                json.dumps(article.get('fullTextUrlList')) if article.get('fullTextUrlList') else None,
                json.dumps(article.get('meshHeadingList')) if article.get('meshHeadingList') else None,
                json.dumps(article.get('keywordList')) if article.get('keywordList') else None
            )

            # --- 插入或忽略 ---
            # "INSERT OR IGNORE" 是去重的关键。
            # 如果 epmc_id (主键) 或 pmid/doi (唯一键) 已存在，则此操作将被静默忽略。
            sql = """
            INSERT OR IGNORE INTO articles (
                epmc_id, pmid, doi, source, pmcid, title, abstract, pub_year, 
                author_string, journal_title, first_publication_date, 
                query_search_term, author_list_json, journal_info_json, 
                full_text_url_list_json, mesh_heading_list_json, keyword_list_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            
            try:
                cursor.execute(sql, data_tuple)
                if cursor.rowcount > 0:
                    inserted_count += 1
                else:
                    skipped_count += 1
            except sqlite3.Error as e:
                print(f"  !! 数据库插入错误 (ID: {epmc_id}): {e}", file=sys.stderr)
                error_count += 1

        # --- 提交事务 ---
        # 在处理完一个文件后提交一次，以提高性能
        conn.commit()
        print(f"  处理完成: {inserted_count} 条新文章已插入， {skipped_count} 条重复/已跳过， {error_count} 条错误。")
        
    return inserted_count, skipped_count, error_count

def main():
    """
    主执行函数
    """
    print("--- 开始 EPMC JSONL 到 SQLite 导入程序 ---")
    
    db_path = DATABASE_FILENAME
    jsonl_dir = Path(JSONL_DIRECTORY)

    if not jsonl_dir.is_dir():
        print(f"!! 错误: 目录不存在: {JSONL_DIRECTORY}", file=sys.stderr)
        print("!! 请检查 JSONL_DIRECTORY 变量是否设置正确。")
        sys.exit(1)
        
    conn = setup_database(db_path)
    if not conn:
        sys.exit(1)

    # 查找所有 .jsonl 文件
    jsonl_files = list(jsonl_dir.glob("*.jsonl"))
    if not jsonl_files:
        print(f"!! 警告: 在 {JSONL_DIRECTORY} 中未找到 .jsonl 文件。")
    
    total_inserted = 0
    total_skipped = 0
    total_errors = 0

    for f_path in jsonl_files:
        inserted, skipped, errors = process_jsonl_file(f_path, conn)
        total_inserted += inserted
        total_skipped += skipped
        total_errors += errors

    # 关闭数据库连接
    conn.close()

    print("\n--- 所有文件处理完毕 ---")
    print(f"总共插入新文章: {total_inserted}")
    print(f"总共跳过 (重复): {total_skipped}")
    print(f"总共发生错误: {total_errors}")
    print(f"数据库已保存到: {db_path}")

if __name__ == "__main__":
    main()

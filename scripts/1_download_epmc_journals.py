import requests
import json
import time
import datetime
from typing import List
from pathlib import Path

# --- 1. 配置 ---
# 从此 .txt 文件读取期刊列表
JOURNAL_FILENAME = "journals.txt"

# 抓取最近 N 天的文章
DAYS_TO_FETCH = 30

# --- 2. API 和输出配置 ---
EPMC_API_URL = "https://www.ebi.ac.uk/europepmc/webservices/rest/search"
# 输出文件名模板
OUTPUT_FILENAME_TEMPLATE = "../download/epmc_download_journals_{timestamp}.jsonl"
PAGE_SIZE = 1000    # API 每页返回的结果数


def load_journals_from_file(filepath: str) -> List[str]:
    """
    从 .txt 文件加载期刊列表。
    - 跳过空行和 '#' 开头的注释行。
    - 去除首尾空白。
    """
    journals = []
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            for line in f:
                cleaned_line = line.strip()
                
                # 保留有效行
                if cleaned_line and not cleaned_line.startswith('#'):
                    journals.append(cleaned_line)
        
        print(f"成功从 {filepath} 加载了 {len(journals)} 个期刊。")

    except FileNotFoundError:
        print(f"!! 错误: 找不到文件 {filepath}")
        print("!! 请检查 JOURNAL_FILENAME 变量是否设置正确。")
        return [] # 返回空列表以安全退出
    except Exception as e:
        print(f"!! 读取文件时出错: {e}")
        return []
        
    return journals

def get_date_query_string(days_ago: int) -> str:
    """获取 EPMC API 的日期查询字符串 (FIRST_PDATE)"""
    start_date = datetime.date.today() - datetime.timedelta(days=days_ago)
    start_date_str = start_date.strftime('%Y-%m-%d')
    # 查询从指定开始日期到未来的所有文章
    return f"FIRST_PDATE:[{start_date_str} TO 2099-12-31]"

def fetch_and_write_articles(journal_list: List[str], date_query: str, f_out) -> int:
    """
    核心函数：针对期刊列表中的每个期刊，获取指定天数内的文章，并以 JSON Lines 格式保存。
    """
    total_fetched_count = 0

    # --- 创建输出目录 ---
    for journal_name in journal_list:
        print(f"\n--- 正在抓取: {journal_name} ---")
        
        # 构建 EPMC 查询语句
        search_query = f'JOURNAL:"{journal_name}" AND {date_query}'
        
        cursorMark = '*' # EPMC 分页游标
        page_num = 1
        journal_total_results = 0

        while True:
            params = {
                'query': search_query,
                'format': 'json',
                'pageSize': PAGE_SIZE,
                'resultType': 'core', # 'core' 包含核心元数据
                'cursorMark': cursorMark,
                'sort_date': 'y' # 按日期排序
            }

            try:
                response = requests.get(EPMC_API_URL, params=params)
                response.raise_for_status() # 检查 HTTP 错误
                data = response.json()
                
            except requests.exceptions.RequestException as e:
                print(f"  !! API 请求失败: {e}")
                break
            except Exception as e:
                print(f"  !! 解析数据时出错: {e}")
                break

            results = data.get('resultList', {}).get('result', [])
            
            if not results:
                if page_num == 1:
                    print(f"  找到 0 篇文章。")
                else:
                    print("  没有更多结果。")
                break
            
            if page_num == 1:
                 print(f"  找到 {data.get('hitCount', 0)} 篇文章。")
            
            print(f"  正在写入第 {page_num} 页 (共 {len(results)} 篇)...")

            # --- 核心：写入 JSON Lines ---
            for article in results:
                # 注入查询时的期刊名，方便溯源
                article['query_journal_name'] = journal_name
                
                # 将字典转换为 JSON 字符串并写入，确保每行一个记录
                f_out.write(json.dumps(article) + '\n')
            # --- 写入结束 ---

            total_fetched_count += len(results)
            
            journal_total_results += len(results)

            # 获取下一页的游标
            nextCursorMark = data.get('nextCursorMark')
            if not nextCursorMark or nextCursorMark == cursorMark:
                break # 没有下一页了
            
            cursorMark = nextCursorMark
            page_num += 1
            time.sleep(0.5) # 礼貌性延迟
        
        print(f"  {journal_name} 完成，共下载 {journal_total_results} 条。")
        # total_articles_written is removed, total_fetched_count is already tracking the total
            
    return total_fetched_count

# --- 脚本执行入口 ---
if __name__ == "__main__":
    print("开始从 Europe PMC 下载文章 (JSON Lines 格式)...")
    
    # 1. 加载期刊
    journal_list_from_file = load_journals_from_file(JOURNAL_FILENAME)

    # 如果列表为空（例如文件未找到或全为空行），则退出
    if not journal_list_from_file:
        print("!! 期刊列表为空，退出程序。")
        exit()

    print(f"待抓取的期刊: {len(journal_list_from_file)} 个")
    
    # 2. 设置日期
    date_range_query = get_date_query_string(DAYS_TO_FETCH)
    print(f"设置查询日期范围: {date_range_query} (最近 {DAYS_TO_FETCH} 天)")
    
    # 3. 准备输出文件
    output_path = Path(OUTPUT_FILENAME_TEMPLATE.format(
        timestamp=datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
    ))

    # 确保输出目录存在
    output_path.parent.mkdir(parents=True, exist_ok=True)
    print(f"将保存到: {output_path}")

    # 4. 执行抓取和写入
    total_count = 0
    try:
        # 使用 'w' 模式打开文件，在循环中持续写入
        with open(output_path, 'w', encoding='utf-8') as f:
            total_count = fetch_and_write_articles(journal_list_from_file, date_range_query, f)
            
        print(f"\n--- 所有操作完成 ---")
        print(f"总共保存了 {total_count} 篇文章到 {output_path}")
        
    except IOError as e:
        print(f"!! 写入文件失败: {e}")
    except Exception as e:
        print(f"!! 发生未知错误: {e}")

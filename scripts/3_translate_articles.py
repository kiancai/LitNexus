import sqlite3
import os
import asyncio
import sys
from openai import AsyncOpenAI, APIError, RateLimitError
from tqdm.asyncio import tqdm_asyncio
import logging

# --- 1. 配置 ---

# 数据库文件名 (使用用户提供的路径)
DATABASE_FILENAME = "../database/epmc_articles.db"

# 并发 API 请求数
CONCURRENT_LIMIT = 100

# API 配置
API_KEY = os.environ.get("ARK_API_KEY") # 使用自己的 ARK_API_KEY。我的 KEY 我定义在自己的 zshrc 中了
BASE_URL = os.environ.get("ARK_API_BASE_URL", "https://ark.cn-beijing.volces.com/api/v3") # 使用 ARK_API_BASE_URL
MODEL_NAME = "doubao-1-5-pro-32k-character-250715" # 使用用户指定的模型

# --- 2. 日志设置 ---
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# 抑制 httpx 的 INFO 级别日志，防止其干扰 tqdm 进度条
logging.getLogger("httpx").setLevel(logging.WARNING)

# --- 3. 数据库操作 ---

def fetch_pending_articles(conn: sqlite3.Connection) -> list:
    """
    获取所有缺少中文标题或摘要的文章。
    """
    logger.info("正在从数据库中获取待翻译的文章...")
    cursor = conn.cursor()
    
    # 选择那些 (原文标题存在 且 中文标题为空) 或 (原文摘要存在 且 中文摘要为空) 的行
    # 同时获取现有的 title_zh 和 abstract_zh 以便后续判断
    query = """
    SELECT epmc_id, title, abstract, title_zh, abstract_zh
    FROM articles 
    WHERE (title IS NOT NULL AND title_zh IS NULL)
       OR (abstract IS NOT NULL AND abstract_zh IS NULL)
    """
    cursor.execute(query)
    articles = cursor.fetchall()
    logger.info(f"共找到 {len(articles)} 篇文章需要处理 (部分或全部翻译)。")
    return articles

def update_article_translation(conn: sqlite3.Connection, epmc_id: str, title_zh: str | None, abstract_zh: str | None):
    """
    将翻译结果更新回数据库。使用 COALESCE 确保 NULL 值不覆盖已有翻译。
    """
    try:
        cursor = conn.cursor()
        # COALESCE(?, title_zh) 表示：如果 ? (新值) 不是 NULL，则使用新值；如果 ? 是 NULL，则保留旧值。
        query = """
        UPDATE articles 
        SET 
            title_zh = COALESCE(?, title_zh),
            abstract_zh = COALESCE(?, abstract_zh)
        WHERE epmc_id = ?
        """
        cursor.execute(query, (title_zh, abstract_zh, epmc_id))
    except sqlite3.Error as e:
        logger.error(f"数据库更新失败 (ID: {epmc_id}): {e}")

# --- 4. AI 翻译 ---

async def translate_text(client: AsyncOpenAI, text: str, task_description: str) -> str | None:
    """
    调用 AI API 翻译单段文本。
    
    :param text: 要翻译的原文
    :param task_description: 任务描述（如“文章标题”、“文章摘要”）
    :return: 翻译后的文本；失败返回 None
    """
    # 检查 None 或空字符串
    if not text or not text.strip():
        # logger.warning(f"跳过翻译空文本 ({task_description})。") # 如果空文本太多，这会刷屏，暂时注释掉
        return "" # 如果原文为空，返回空字符串，COALESCE 会将其存入

    system_prompt = (
        "You are a professional academic translator. "
        "Translate the following text into concise, accurate, and professional Chinese. "
        f"The text is a(n) '{task_description}'. "
        "Respond with *only* the translation, nothing else."
    )
    
    try:
        response = await client.chat.completions.create(
            model=MODEL_NAME, # 使用配置的模型名称
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": text}
            ],
            temperature=0.1,
        )
        translation = response.choices[0].message.content
        return translation.strip()
        
    except RateLimitError:
        logger.warning(f"已达到速率限制 (ID: {text[:30]}...)，将稍后重试...")
        await asyncio.sleep(30) # 等待 30 秒
        return await translate_text(client, text, task_description) # 重试
    except APIError as e:
        logger.error(f"API 发生错误 (ID: {text[:30]}...): {e}")
        return None
    except Exception as e:
        logger.error(f"翻译过程中发生未知错误 (ID: {text[:30]}...): {e}")
        return None

# --- 5. 主流程 ---

async def process_article(client: AsyncOpenAI, semaphore: asyncio.Semaphore, article_data: tuple) -> tuple:
    """
    单个文章的完整处理工作流（获取信号、按需翻译）。
    """
    # article_data 包含 epmc_id, title, abstract, title_zh, abstract_zh
    epmc_id, title, abstract, existing_title_zh, existing_abstract_zh = article_data
    
    new_title_translation = None
    new_abstract_translation = None
    
    async with semaphore:
        try:
            tasks_to_run = []
            # 1. 决定是否需要翻译标题
            if existing_title_zh is None and title is not None and title.strip():
                # 添加翻译标题的任务
                tasks_to_run.append(translate_text(client, title, "article title"))
            else:
                # 添加一个返回 None 的占位任务
                tasks_to_run.append(asyncio.sleep(0, result=None)) # 使用 sleep(0) 作为返回 None 的占位任务

            # 2. 决定是否需要翻译摘要
            if existing_abstract_zh is None and abstract is not None and abstract.strip():
                # 添加翻译摘要的任务
                tasks_to_run.append(translate_text(client, abstract, "article abstract"))
            else:
                # 添加一个返回 None 的占位任务
                tasks_to_run.append(asyncio.sleep(0, result=None)) # 使用 sleep(0) 作为返回 None 的占位任务
            
            # 3. 并行执行需要运行的任务
            # 如果 tasks_to_run 仅包含占位任务，gather 会快速返回 [None, None]
            results = await asyncio.gather(*tasks_to_run)
            new_title_translation = results[0]
            new_abstract_translation = results[1]

            # 4. 返回新翻译的内容 (失败或不需要则为 None)
            return epmc_id, new_title_translation, new_abstract_translation

        except Exception as e:
            logger.error(f"处理 ID: {epmc_id} 时发生错误: {e}")
            return epmc_id, None, None # 确保返回元组

async def main():
    """
    主异步执行函数。
    """
    if not API_KEY:
        logger.error("错误: 未设置 ARK_API_KEY 环境变量。")
        logger.error("请先设置: export ARK_API_KEY='your_api_key_here'")
        sys.exit(1)
        
    logger.info("--- 开始 AI 翻译流程 (v3) ---")
    
    conn = None
    try:
        # 检查数据库文件是否存在
        if not os.path.exists(DATABASE_FILENAME):
             logger.error(f"错误: 数据库文件未找到: {DATABASE_FILENAME}")
             sys.exit(1)

        # 连接数据库并设置
        conn = sqlite3.connect(DATABASE_FILENAME)
        
        articles = fetch_pending_articles(conn)
        
        if not articles:
            logger.info("没有需要翻译的文章。程序退出。")
            return

        # 初始化 AI 客户端和并发信号量
        client = AsyncOpenAI(api_key=API_KEY, base_url=BASE_URL)
        semaphore = asyncio.Semaphore(CONCURRENT_LIMIT)
        
        tasks = [process_article(client, semaphore, article) for article in articles]
        
        logger.info(f"开始处理 {len(tasks)} 篇文章，并发数: {CONCURRENT_LIMIT}...")
        
        processed_count = 0
        update_attempts = 0 # 记录尝试更新的次数
        
        # 使用 tqdm_asyncio.as_completed 处理任务，并在完成时立即获取结果
        for future in tqdm_asyncio.as_completed(tasks, total=len(tasks), desc="翻译进度"):
            try:
                # 等待任务完成并获取结果
                epmc_id, new_title_zh, new_abstract_zh = await future
            except Exception as e:
                # 处理在 process_article 内部未捕获的或 gather 本身的错误
                logger.error(f"一个任务协程在等待结果时失败: {e}")
                processed_count += 1 # 仍然算作已处理，但不会更新
                continue # 跳过这个任务
                
            processed_count += 1
            
            # 只要有任何一个翻译结果（即使是空字符串""），就尝试更新
            if new_title_zh is not None or new_abstract_zh is not None:
                update_article_translation(conn, epmc_id, new_title_zh, new_abstract_zh)
                update_attempts += 1


            # 每处理 50 篇文章提交一次事务，以防脚本中断
            # 基于处理计数而不是更新计数，确保即使有失败也能保存成功的部分
            if processed_count % 50 == 0:
                logger.info(f"\n已处理 {processed_count} / {len(tasks)} 篇，正在保存进度到数据库...")
                conn.commit()
                
        # 循环结束，提交所有剩余的更改
        logger.info("所有文章处理尝试完毕，正在执行最终保存...")
        conn.commit()
        
        logger.info(f"--- 流程完毕 ---")
        logger.info(f"总共处理文章条目: {processed_count}")
        logger.info(f"尝试更新数据库的条目: {update_attempts}") # 注意：这不代表翻译一定成功，只代表至少有一个字段需要更新且未在 API 调用中出错


    except sqlite3.Error as e:
        logger.error(f"发生数据库错误: {e}")
    except Exception as e:
        logger.error(f"发生未处理的主流程错误: {e}")
    finally:
        if conn:
            conn.close()
            logger.info("数据库连接已关闭。")

if __name__ == "__main__":
    # 运行异步主函数
    asyncio.run(main())


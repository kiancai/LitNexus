import pandas as pd
import os
import json
import time
import concurrent.futures # 导入并发库
from openai import OpenAI
from tqdm import tqdm # 用于显示漂亮的进度条

# --- 配置区域 ---

# 1. API 密钥和终结点 (Base URL)
API_KEY = os.environ.get("ARK_API_KEY") # 使用 ARK_API_KEY
BASE_URL = os.environ.get("ARK_API_BASE_URL", "https://ark.cn-beijing.volces.com/api/v3") # 使用 ARK_API_BASE_URL

# 2. AI 模型名称
MODEL_NAME = "doubao-1-5-pro-32k-character-250715" # 可按需更换模型

# 3. 文件路径
INPUT_FILE = '../database/exported_articles.csv' # 您的输入文件名
OUTPUT_FILE = '../database/exported_articles_analyzed.csv' # 输出文件名

# 4. 并行配置
MAX_WORKERS = 100 # 并行工作的线程数

# --- 提示工程 ---

# 强制 AI 以 JSON 格式返回，以便我们可靠地解析
SYSTEM_PROMPT = """
你是一个专注、严谨的科研领域分类专家。你的核心任务是根据用户提供的论文标题（Title）和摘要（Abstract），对两个具体问题进行分类判断，并一次性给出结果。

当摘要或标题中有一个存在缺失时，则仅依据存在的信息进行判断。

你的判断需要非常准确。请仔细分析文本的每一个词，特别是专业术语。

你的回答必须且只能是一个 JSON 对象，不包含任何 JSON 格式之外的封装、Markdown 标记或解释性文字。
JSON 结构必须严格如下所示：
{
  "q1": {
    "answer": "是" | "否",
    "reason": "请提供一个简洁、专业、不超过 100 个字的判断理由。"
  },
  "q2": {
    "answer": "是" | "否",
    "reason": "请提供一个简洁、专业、不超过 200 个字的判断理由。"
  }
}
"""

# 您要问的两个问题（加强版：补充判定准则与边界说明）
# QUESTION_1 = "请判断本文是否属于生物学或医学领域。若标题或摘要聚焦于生命体（人/微生物）、细胞/分子/基因/蛋白/代谢、疾病/临床/公共卫生、实验方法，或与上述对象直接相关的数据与应用，则回答‘是’；若主要讨论纯算法、物理、化学工程、通用计算且无明确生物/医学应用证据，则回答‘否’。"
# QUESTION_2 = "请判断本文是否属于以下任一类别：(a) 人体微生物领域（human microbiome，含肠道/口腔/皮肤等微生物群研究，16S rRNA/宏基因组/宏转录组，菌群与健康或疾病关联）；(b) 生物学相关的语言模型研究（针对基因/蛋白/生物文本或生物数据的 LLM/Transformer/表示学习等）；(c) 与生物学或医学相关的人工智能或机器学习研究（含深度学习、传统 ML 方法），例如用于生物数据解析、分子/基因预测、临床或公共卫生应用；(d) 病毒学/病原体/传染病研究（含人类病毒与人类相关病原微生物，病毒组/病原体监测，流行病学建模）；(e) 生物信息学/计算生物学（如序列分析、组学数据处理、比对与变异检测、表达分析、网络/通路分析、结构生物信息学等）。若摘要仅涉及一般统计或算法方法且未用于生物数据或生物问题，或 AI/ML 与生物医学无关，则回答‘否’。"

QUESTION_1 = "请判断本文是否属于‘计算生物学、生物信息学、生物医学’或相关交叉领域。若文章属于以下任一类型，请回答‘是’：(1) 涉及组学数据（基因/蛋白/代谢等）的分析或实验研究；(2) 涉及生物算法、模型、软件工具或数据库的开发与应用；(3) **对上述相关领域的综述 (Review)、系统评价、进展总结或观点展望**。仅当文章是纯粹的临床护理个案、社会学调查、或完全不涉及生物医学背景的纯数学/计算机理论时，才回答‘否’。"
QUESTION_2 = "请判断本文是否属于以下任一核心关注领域（命中任意一项即回答‘是’）：(a) 微生物组学（Microbiome）：涵盖人体（呼吸道/肠道）或环境微生物群落、宏基因组/宏转录组分析、菌群功能预测、去污染及分箱技术；(b) 生物基础模型与生成式AI（Biological Foundation Models & LLMs）：涉及针对 DNA/RNA/蛋白质序列的语言模型（如 DNABERT, Evo），或针对单细胞/空间组学的预训练/嵌入模型（Cell Embeddings, scGPT）；(c) 生物医学机器学习应用：使用深度学习/AI 解决具体生物问题，或相关的算法基准测试（Benchmarking）；(d) 病毒与病原体计算：涉及病毒组、病原体检测、耐药基因或流行病学建模；(e) 生物信息核心工具：涉及序列比对、数据质控、流程管理（Snakemake等）或多组学整合分析。若均不属于，回答‘否’。"

def is_empty_cell(val):
    try:
        if val is None or pd.isna(val):
            return True
    except Exception:
        pass
    return isinstance(val, str) and val.strip() == ""

def get_ai_dual_analysis(client, title, abstract):
    """
    调用 AI API，一次性回答两个问题。
    返回: (q1_ans, q1_rea, q2_ans, q2_rea)
    """

    user_message = f"""
    请根据以下信息回答两个问题，并按指定 JSON 结构返回：

    【标题】: {title}
    【摘要】: {abstract}

    【问题1】: {QUESTION_1}
    【问题2】: {QUESTION_2}

    请仅以JSON格式返回你的答案。
    """

    try:
        response = client.chat.completions.create(
            model=MODEL_NAME,
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_message}
            ],
            temperature=0.0
        )

        content = response.choices[0].message.content
        data = json.loads(content)

        # 验证返回结构
        if (
            "q1" in data and "q2" in data and
            isinstance(data["q1"], dict) and isinstance(data["q2"], dict) and
            "answer" in data["q1"] and "reason" in data["q1"] and
            "answer" in data["q2"] and "reason" in data["q2"]
        ):
            return (
                data["q1"]["answer"], data["q1"]["reason"],
                data["q2"]["answer"], data["q2"]["reason"]
            )
        else:
            print(f"  [警告] API 返回的 JSON 格式不正确: {content}")
            return (
                "JSON格式错误", "缺少 q1/q2 或字段",
                "JSON格式错误", "缺少 q1/q2 或字段"
            )

    except Exception as e:
        print(f"  [错误] API 调用失败: {e}")
        return "API错误", str(e), "API错误", str(e)


def process_row(args):
    """
    处理单行数据的函数，用于并行化。
    参数: args (tuple) - 包含 (row_tuple, client)
         row_tuple (namedtuple) - 来自 df.itertuples() 的单行数据
         client (OpenAI) - API 客户端
    返回:
         (dict) - 处理后包含新数据的行字典
    """
    row_tuple, client = args
    
    # 将 itertuples 的 namedtuple 转换为可写的字典
    row_dict = row_tuple._asdict()
    
    title = str(row_dict.get('title', ''))
    abstract = str(row_dict.get('abstract', ''))

    # 读取已有结果
    q1_existing = row_dict.get('q1_ans', None)
    q1_rea_existing = row_dict.get('q1_rea', None)
    q2_existing = row_dict.get('q2_ans', None)
    q2_rea_existing = row_dict.get('q2_rea', None)

    # 仅当 q1_ans 为空时才调用模型；否则保留已有结果
    if not title.strip() or not abstract.strip():
        q1_ans = q1_existing if not is_empty_cell(q1_existing) else "N/A"
        q1_rea = q1_rea_existing if not is_empty_cell(q1_rea_existing) else "缺少标题或摘要"
        q2_ans = q2_existing if not is_empty_cell(q2_existing) else "N/A"
        q2_rea = q2_rea_existing if not is_empty_cell(q2_rea_existing) else "缺少标题或摘要"
    else:
        if is_empty_cell(q1_existing):
            q1_ans, q1_rea, q2_ans, q2_rea = get_ai_dual_analysis(client, title, abstract)
        else:
            q1_ans, q1_rea = q1_existing, q1_rea_existing
            q2_ans, q2_rea = q2_existing, q2_rea_existing

    # 按要求覆盖或填充列
    row_dict['q1_ans'] = q1_ans
    row_dict['q1_rea'] = q1_rea
    row_dict['q2_ans'] = q2_ans
    row_dict['q2_rea'] = q2_rea
    
    return row_dict


def main():
    """
    主执行函数
    """
    print(f"正在初始化 OpenAI 客户端...")
    print(f"  Base URL: {BASE_URL}")
    print(f"  Model: {MODEL_NAME}")
    
    # 修正 API KEY 检查
    if not API_KEY:
        print("\n" + "="*50)
        print("!! 警告: 环境变量 'ARK_API_KEY' 未设置。")
        print("   请确保已正确设置 'ARK_API_KEY'。")
        print("="*50 + "\n")
        return

    try:
        client = OpenAI(api_key=API_KEY, base_url=BASE_URL)
    except Exception as e:
        print(f"创建 OpenAI 客户端失败: {e}")
        return

    print(f"正在读取输入文件: {INPUT_FILE}...")
    try:
        df = pd.read_csv(INPUT_FILE)
    except FileNotFoundError:
        print(f"错误: 未找到输入文件 '{INPUT_FILE}'。")
        return
    except Exception as e:
        print(f"读取 CSV 文件时出错: {e}")
        return

    # 检查必需的列
    if 'title' not in df.columns or 'abstract' not in df.columns:
        print("错误: CSV 文件中必须包含 'title' 和 'abstract' 列。")
        return

    # 检查 (并创建) 目标列
    target_cols = ['q1_ans', 'q1_rea', 'q2_ans', 'q2_rea']
    for col in target_cols:
        if col not in df.columns:
            print(f"  [信息] 目标列 '{col}' 不存在，将创建新列。")
            df[col] = pd.NA # 初始化为 NA

    print(f"找到了 {len(df)} 篇文章。开始并行处理 (最多 {MAX_WORKERS} 个线程)...")

    # 准备任务列表
    # df.itertuples(index=True) 会包含 Index，用于后续排序
    tasks = [(row_tuple, client) for row_tuple in df.itertuples(index=True)]
    
    results = []

    # 使用 ThreadPoolExecutor 进行并行处理
    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        # 使用 as_completed 来获取结果（顺序会乱）
        futures = {executor.submit(process_row, task): task for task in tasks}
        
        for future in tqdm(concurrent.futures.as_completed(futures), total=len(tasks), desc="分析进度"):
            try:
                result_row_dict = future.result()
                results.append(result_row_dict)
            except Exception as e:
                task_info = futures[future] # 获取原始任务信息
                row_index = task_info[0].Index # 获取行索引
                print(f"  [严重错误] 处理第 {row_index + 1} 行时发生异常: {e}")

    print("\n处理完成！")
    
    # 将结果列表转换为新的 DataFrame
    if not results:
        print("没有处理任何数据。")
        return
        
    output_df = pd.DataFrame(results)
    
    # 按原始索引 (Index) 排序，以确保顺序与输入文件一致
    output_df = output_df.sort_values(by='Index').reset_index(drop=True)
    
    # 移除 'Index' 列，因为它是由 itertuples 添加的
    if 'Index' in output_df.columns:
        output_df = output_df.drop(columns=['Index'])
    
    print(f"正在保存结果到: {OUTPUT_FILE}...")
    try:
        # 使用 utf-8-sig 编码确保 Excel 能正确打开中文
        output_df.to_csv(OUTPUT_FILE, index=False, encoding='utf-8-sig')
        print("分析完成！")
    except Exception as e:
        print(f"保存文件时出错: {e}")

if __name__ == "__main__":
    main()


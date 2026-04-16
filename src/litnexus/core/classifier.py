"""AI 双问题分类模块（ThreadPoolExecutor 并发）。"""

from __future__ import annotations

import concurrent.futures
import json
import logging
from pathlib import Path

import pandas as pd
from openai import OpenAI
from tqdm import tqdm

from litnexus.core.config import ClassifyConfig, AIConfig
from litnexus.core.io import normalize_value

logger = logging.getLogger(__name__)

_SYSTEM_PROMPT = """\
你是一个专注、严谨的科研领域分类专家。你的核心任务是根据用户提供的论文标题（Title）和摘要（Abstract），\
对两个具体问题进行分类判断，并一次性给出结果。

当摘要或标题中有一个存在缺失时，则仅依据存在的信息进行判断。

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
}"""


def _call_ai(
    client: OpenAI,
    model: str,
    title: str,
    abstract: str,
    question_1: str,
    question_2: str,
) -> tuple[str, str, str, str]:
    """调用 AI，返回 (q1_ans, q1_rea, q2_ans, q2_rea)。"""
    user_msg = (
        f"请根据以下信息回答两个问题，并按指定 JSON 结构返回：\n\n"
        f"【标题】: {title}\n【摘要】: {abstract}\n\n"
        f"【问题1】: {question_1}\n【问题2】: {question_2}\n\n"
        "请仅以JSON格式返回你的答案。"
    )
    resp = client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": _SYSTEM_PROMPT},
            {"role": "user", "content": user_msg},
        ],
        temperature=0.0,
    )
    content = resp.choices[0].message.content
    data = json.loads(content)
    if (
        "q1" in data and "q2" in data
        and "answer" in data["q1"] and "reason" in data["q1"]
        and "answer" in data["q2"] and "reason" in data["q2"]
    ):
        return (
            data["q1"]["answer"], data["q1"]["reason"],
            data["q2"]["answer"], data["q2"]["reason"],
        )
    raise ValueError(f"JSON 格式不符合预期：{content[:200]}")


def _process_row(args: tuple) -> dict:
    """线程池工作函数。"""
    row_dict, api_key, base_url, model, question_1, question_2 = args
    title = str(row_dict.get("title") or "")
    abstract = str(row_dict.get("abstract") or "")
    q1_existing = normalize_value(row_dict.get("q1_ans"))

    # 如果已有分类结果则跳过
    if q1_existing is not None:
        return row_dict

    if not title.strip() and not abstract.strip():
        row_dict["q1_ans"] = "N/A"
        row_dict["q1_rea"] = "缺少标题和摘要"
        row_dict["q2_ans"] = "N/A"
        row_dict["q2_rea"] = "缺少标题和摘要"
        return row_dict

    client = OpenAI(api_key=api_key, base_url=base_url)
    try:
        q1_ans, q1_rea, q2_ans, q2_rea = _call_ai(
            client, model, title, abstract, question_1, question_2
        )
    except Exception as e:
        logger.error(f"API 调用失败：{e}")
        q1_ans = q2_ans = "API错误"
        q1_rea = q2_rea = str(e)

    row_dict["q1_ans"] = q1_ans
    row_dict["q1_rea"] = q1_rea
    row_dict["q2_ans"] = q2_ans
    row_dict["q2_rea"] = q2_rea
    return row_dict


def run_classification(
    input_csv: Path,
    output_csv: Path,
    cfg: ClassifyConfig,
    ai_cfg: AIConfig,
) -> tuple[int, int]:
    """完整分类流程，返回 (processed, skipped)。"""
    df = pd.read_csv(input_csv)
    for col in ("q1_ans", "q1_rea", "q2_ans", "q2_rea"):
        if col not in df.columns:
            df[col] = pd.NA

    tasks = [
        (
            row._asdict(),
            ai_cfg.api_key,
            ai_cfg.base_url,
            ai_cfg.model,
            cfg.question_1,
            cfg.question_2,
        )
        for row in df.itertuples(index=True)
    ]

    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=cfg.max_workers) as executor:
        futures = {executor.submit(_process_row, task): task for task in tasks}
        for future in tqdm(
            concurrent.futures.as_completed(futures), total=len(tasks), desc="分类进度"
        ):
            try:
                results.append(future.result())
            except Exception as e:
                logger.error(f"任务异常：{e}")

    processed = len(results)
    skipped = len(df) - processed

    out_df = pd.DataFrame(results)
    if "Index" in out_df.columns:
        out_df = out_df.sort_values("Index").drop(columns=["Index"])
    out_df = out_df.reset_index(drop=True)

    output_csv.parent.mkdir(parents=True, exist_ok=True)
    out_df.to_csv(output_csv, index=False, encoding="utf-8-sig")
    return processed, skipped

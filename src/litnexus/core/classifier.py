"""AI 多问题分类模块（ThreadPoolExecutor 并发，直接读写数据库）。

设计原则：
- 每篇文章一次 API 调用，同时回答所有配置的问题
- 每篇处理完立即写入 DB（各线程独立连接，SQLite WAL 自动串行化写入）
- 已有答案的列用 COALESCE 保护，不覆盖
"""

from __future__ import annotations

import concurrent.futures
import json
import logging
import re
import sqlite3
from pathlib import Path

from openai import OpenAI
from tqdm import tqdm

from litnexus.core.config import ClassifyConfig, AIConfig, Question

logger = logging.getLogger(__name__)


def _build_system_prompt(questions: list[Question]) -> str:
    """根据问题列表动态生成 system prompt。"""
    q_json_lines = ",\n".join(
        f'  "{q.id}": {{"answer": "是"|"否", "reason": "简洁理由（不超过200字）"}}'
        for q in questions
    )
    return (
        "你是一个严谨的科研领域分类专家。"
        "根据提供的论文标题和摘要，回答以下所有问题。"
        "标题或摘要缺失时，仅依据现有信息判断。\n\n"
        "你的回答必须是且仅是一个 JSON 对象，不包含任何 Markdown 或解释性文字，结构如下：\n"
        "{\n" + q_json_lines + "\n}"
    )


def _parse_response(content: str, questions: list[Question]) -> dict[str, tuple[str, str]]:
    """解析 AI 回复，返回 {question_id: (answer, reason)}。

    多层降级：直接解析 → 提取代码块 → 失败返回空 dict。
    """
    def _extract(data: dict) -> dict[str, tuple[str, str]]:
        result = {}
        for q in questions:
            if q.id in data and isinstance(data[q.id], dict):
                ans = data[q.id].get("answer", "")
                rea = data[q.id].get("reason", "")
                result[q.id] = (ans, rea)
        return result

    # 层1：直接解析
    try:
        return _extract(json.loads(content))
    except (json.JSONDecodeError, AttributeError):
        pass

    # 层2：提取 ```json ... ``` 代码块
    m = re.search(r"```(?:json)?\s*([\s\S]*?)```", content)
    if m:
        try:
            return _extract(json.loads(m.group(1)))
        except (json.JSONDecodeError, AttributeError):
            pass

    return {}


def _call_ai(
    client: OpenAI,
    model: str,
    title: str,
    abstract: str,
    questions: list[Question],
) -> dict[str, tuple[str, str]]:
    """调用 AI，返回 {question_id: (answer, reason)}。"""
    q_text = "\n".join(f"【问题 {q.id}】{q.text}" for q in questions)
    user_msg = (
        f"【标题】{title}\n"
        f"【摘要】{abstract}\n\n"
        f"{q_text}"
    )
    system_prompt = _build_system_prompt(questions)

    resp = client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_msg},
        ],
        temperature=0.0,
    )
    return _parse_response(resp.choices[0].message.content, questions)


def _process_row(args: tuple) -> tuple[str, bool]:
    """线程池工作函数：处理一篇文章，结果立即写入 DB。

    返回 (epmc_id, success)。
    """
    epmc_id, title, abstract, api_key, base_url, model, questions, db_path = args

    title = title or ""
    abstract = abstract or ""
    if not title.strip() and not abstract.strip():
        _write_results(
            db_path, epmc_id,
            {q.id: ("N/A", "缺少标题和摘要") for q in questions}
        )
        return epmc_id, True

    client = OpenAI(api_key=api_key, base_url=base_url)
    try:
        results = _call_ai(client, model, title, abstract, questions)
        if not results:
            raise ValueError("解析结果为空")
    except Exception as e:
        logger.error(f"分类失败 ({epmc_id}): {e}")
        results = {q.id: ("API错误", str(e)[:200]) for q in questions}

    _write_results(db_path, epmc_id, results)
    return epmc_id, True


def _write_results(
    db_path: Path,
    epmc_id: str,
    results: dict[str, tuple[str, str]],
) -> None:
    """将分类结果写入 DB（COALESCE 保护已有值）。每线程独立连接。"""
    if not results:
        return
    set_parts = []
    params = []
    for q_id, (ans, rea) in results.items():
        set_parts.append(f"{q_id}_ans = COALESCE(?, {q_id}_ans)")
        set_parts.append(f"{q_id}_rea = COALESCE(?, {q_id}_rea)")
        params.extend([ans, rea])
    params.append(epmc_id)

    conn = sqlite3.connect(db_path)
    try:
        conn.execute(
            f"UPDATE articles SET {', '.join(set_parts)} WHERE epmc_id = ?",
            params,
        )
        conn.commit()
    finally:
        conn.close()


def run_classification(
    db_path: Path,
    cfg: ClassifyConfig,
    cfg_ai: AIConfig,
) -> tuple[int, int]:
    """完整分类流程（直接读写 DB），返回 (processed, failed)。"""
    questions = cfg.questions
    if not questions:
        logger.warning("未配置任何问题，跳过分类。")
        return 0, 0

    # 查询待分类文章
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        null_checks = " OR ".join(f"{q.id}_ans IS NULL" for q in questions)
        rows = conn.execute(
            f"SELECT epmc_id, title, abstract FROM articles "
            f"WHERE ({null_checks}) AND (title IS NOT NULL OR abstract IS NOT NULL)"
        ).fetchall()
        pending = [dict(r) for r in rows]
    finally:
        conn.close()

    if not pending:
        logger.info("没有需要分类的文章。")
        return 0, 0

    logger.info(f"共 {len(pending)} 篇待分类")

    tasks = [
        (
            row["epmc_id"],
            row.get("title") or "",
            row.get("abstract") or "",
            cfg_ai.api_key,
            cfg_ai.base_url,
            cfg_ai.model,
            questions,
            db_path,
        )
        for row in pending
    ]

    processed = failed = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=cfg.max_workers) as executor:
        futures = {executor.submit(_process_row, t): t for t in tasks}
        for future in tqdm(
            concurrent.futures.as_completed(futures),
            total=len(tasks),
            desc="分类进度",
        ):
            try:
                _, success = future.result()
                if success:
                    processed += 1
                else:
                    failed += 1
            except Exception as e:
                logger.error(f"任务异常：{e}")
                failed += 1

    return processed, failed

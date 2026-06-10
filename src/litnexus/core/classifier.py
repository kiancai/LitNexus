"""AI 多问题分类模块（ThreadPoolExecutor 并发调用 AI，主线程读写数据库）。

设计原则：
- 每篇文章一次 API 调用，同时回答所有配置的问题
- 分类结果缓冲至 BUFFER_SIZE 条后批量写入 DB，兼顾性能与中断可恢复性
- 已有答案的列用 COALESCE 保护，不覆盖
- API/解析失败的文章不写库（_ans 保持 NULL），因此下次运行会自动重试
- 复用调用方传入的、已迁移并启用 WAL 的连接（不再自行 sqlite3.connect）
"""

from __future__ import annotations

import concurrent.futures
import json
import logging
import re
import sqlite3
import time
from typing import Any

from openai import OpenAI, RateLimitError
from tqdm import tqdm

from litnexus.core import db as db_mod
from litnexus.core.config import AIConfig, ClassifyConfig, Question

logger = logging.getLogger(__name__)

_BUFFER_SIZE = 50  # 每积累多少条结果批量写入一次 DB

# 限流退避：最多重试 _MAX_RETRIES 次，第 n 次等待 min(BASE*2^n, CAP) 秒
_MAX_RETRIES = 5
_BACKOFF_BASE = 2.0
_BACKOFF_CAP = 60.0


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

    for attempt in range(_MAX_RETRIES + 1):
        try:
            resp = client.chat.completions.create(
                model=model,
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_msg},
                ],
                temperature=0.0,
            )
            break
        except RateLimitError:
            if attempt >= _MAX_RETRIES:
                raise
            delay = min(_BACKOFF_BASE * (2**attempt), _BACKOFF_CAP)
            logger.warning(
                f"触发速率限制，{delay:.0f}s 后重试（第 {attempt + 1}/{_MAX_RETRIES} 次）..."
            )
            time.sleep(delay)
    content = resp.choices[0].message.content
    return _parse_response(content or "", questions)


def _process_row(args: tuple) -> tuple[str, dict[str, tuple[str, str]]]:
    """线程池工作函数：处理一篇文章，返回 (epmc_id, results)。

    - 成功：results = {question_id: (answer, reason)}
    - 缺标题和摘要：results = {question_id: ("N/A", "缺少标题和摘要")}（终态，不再重试）
    - API/解析失败：results = {}（不写库，_ans 保持 NULL，下次运行自动重试）
    """
    epmc_id, title, abstract, api_key, base_url, model, questions = args

    title = title or ""
    abstract = abstract or ""
    if not title.strip() and not abstract.strip():
        return epmc_id, {q.id: ("N/A", "缺少标题和摘要") for q in questions}

    client = OpenAI(api_key=api_key, base_url=base_url)
    try:
        results = _call_ai(client, model, title, abstract, questions)
        if not results:
            raise ValueError("解析结果为空")
    except Exception as e:
        logger.error(f"分类失败 ({epmc_id}): {e}")
        return epmc_id, {}  # 失败不落库，保持 _ans 为 NULL 以便下次重试

    return epmc_id, results


def _write_batch(
    conn: sqlite3.Connection,
    batch: list[tuple[str, dict[str, tuple[str, str]]]],
) -> None:
    """批量将分类结果写入 DB（COALESCE 保护已有值）。在主线程用传入的连接执行。"""
    for epmc_id, results in batch:
        if not results:
            continue
        set_parts = []
        params = []
        for q_id, (ans, rea) in results.items():
            set_parts.append(f"{q_id}_ans = COALESCE(?, {q_id}_ans)")
            set_parts.append(f"{q_id}_rea = COALESCE(?, {q_id}_rea)")
            params.extend([ans, rea])
        params.append(epmc_id)
        conn.execute(
            f"UPDATE articles SET {', '.join(set_parts)} WHERE epmc_id = ?",
            params,
        )
    conn.commit()


def run_classification(
    conn: sqlite3.Connection,
    cfg: ClassifyConfig,
    cfg_ai: AIConfig,
    reporter: Any | None = None,
) -> tuple[int, int]:
    """完整分类流程，返回 (processed, failed)。

    conn 须是已迁移、且动态问题列已就绪的连接（如 db.get_connection 返回的连接）。
    工作线程只负责调用 AI，所有数据库读写都在主线程用 conn 串行完成。
    失败的文章不写库（_ans 保持 NULL），下次运行会自动重试。
    """
    questions = cfg.questions
    if not questions:
        logger.warning("未配置任何问题，跳过分类。")
        return 0, 0

    pending = db_mod.fetch_pending_classification(conn, questions)
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
        )
        for row in pending
    ]

    processed = failed = 0
    buffer: list[tuple[str, dict[str, tuple[str, str]]]] = []

    with concurrent.futures.ThreadPoolExecutor(max_workers=cfg.max_workers) as executor:
        futures = {executor.submit(_process_row, t): t for t in tasks}
        task_id = (
            reporter.add_task("AI 分类", total=len(tasks)) if reporter is not None else None
        )
        completed = concurrent.futures.as_completed(futures)
        if reporter is None:
            completed = tqdm(completed, total=len(tasks), desc="分类进度")
        for future in completed:
            try:
                epmc_id, results = future.result()
            except Exception as e:
                logger.error(f"任务异常：{e}")
                failed += 1
            else:
                if results:
                    buffer.append((epmc_id, results))
                    processed += 1
                    if len(buffer) >= _BUFFER_SIZE:
                        _write_batch(conn, buffer)
                        buffer.clear()
                else:
                    failed += 1  # API/解析失败：未写库，_ans 仍为 NULL
            if reporter is not None:
                reporter.update(task_id, advance=1)

    if buffer:
        _write_batch(conn, buffer)

    if reporter is not None:
        reporter.complete(task_id)
    return processed, failed

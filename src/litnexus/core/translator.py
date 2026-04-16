"""批量翻译模块（只翻译标题，AsyncOpenAI）。

优化：每次 API 调用翻译 batch_size 个标题（默认30），用 id 字段匹配，多层降级解析。
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
import sqlite3

from openai import AsyncOpenAI, APIError, RateLimitError
from tqdm.asyncio import tqdm_asyncio

from litnexus.core import db as db_mod
from litnexus.core.config import TranslateConfig, AIConfig

logger = logging.getLogger(__name__)
logging.getLogger("httpx").setLevel(logging.WARNING)

_SYSTEM_PROMPT = (
    "You are a professional academic translator. "
    "Translate each English article title into concise, accurate Chinese. "
    "Input is a JSON array; return a JSON array of the same length in the same order. "
    "Output ONLY the JSON array, no markdown, no explanation.\n"
    'Input:  [{"id": 1, "title": "..."}, ...]\n'
    'Output: [{"id": 1, "title_zh": "..."}, ...]'
)


def _parse_batch_response(content: str, expected_ids: list[int]) -> dict[int, str]:
    """多层降级解析，返回 {id: title_zh}。"""
    # 层1：直接解析
    try:
        data = json.loads(content)
        if isinstance(data, list):
            return {item["id"]: item["title_zh"] for item in data
                    if "id" in item and "title_zh" in item}
    except (json.JSONDecodeError, KeyError):
        pass

    # 层2：提取代码块
    m = re.search(r"```(?:json)?\s*([\s\S]*?)```", content)
    if m:
        try:
            data = json.loads(m.group(1))
            if isinstance(data, list):
                return {item["id"]: item["title_zh"] for item in data
                        if "id" in item and "title_zh" in item}
        except (json.JSONDecodeError, KeyError):
            pass

    # 层3：逐条正则
    result = {}
    for m in re.finditer(r'"id"\s*:\s*(\d+).*?"title_zh"\s*:\s*"(.*?)"', content, re.DOTALL):
        result[int(m.group(1))] = m.group(2)
    return result


async def _translate_single(
    client: AsyncOpenAI, epmc_id: str, title: str, cfg_ai: AIConfig
) -> str | None:
    """单条回退翻译。"""
    try:
        resp = await client.chat.completions.create(
            model=cfg_ai.model,
            messages=[
                {"role": "system", "content": "You are a professional academic translator. Translate the English article title into concise, accurate Chinese. Output ONLY the translation."},
                {"role": "user", "content": title},
            ],
            temperature=0.1,
        )
        return resp.choices[0].message.content.strip()
    except Exception as e:
        logger.warning(f"单条翻译失败 ({epmc_id}): {e}")
        return None


async def _translate_batch(
    client: AsyncOpenAI,
    batch: list[tuple[str, str]],
    cfg_ai: AIConfig,
) -> list[tuple[str, str | None]]:
    """翻译一批标题，返回 [(epmc_id, title_zh | None)]。"""
    id_to_epmc = {i + 1: epmc_id for i, (epmc_id, _) in enumerate(batch)}
    payload = [{"id": i + 1, "title": title} for i, (_, title) in enumerate(batch)]

    try:
        resp = await client.chat.completions.create(
            model=cfg_ai.model,
            messages=[
                {"role": "system", "content": _SYSTEM_PROMPT},
                {"role": "user", "content": json.dumps(payload, ensure_ascii=False)},
            ],
            temperature=0.1,
        )
        content = resp.choices[0].message.content.strip()
    except RateLimitError:
        logger.warning("触发速率限制，等待 30 秒后重试...")
        await asyncio.sleep(30)
        return await _translate_batch(client, batch, cfg_ai)
    except APIError as e:
        logger.error(f"API 错误：{e}")
        return [(epmc_id, None) for epmc_id, _ in batch]

    parsed = _parse_batch_response(content, list(id_to_epmc.keys()))
    batch_dict = dict(batch)

    results = []
    missing = []
    for local_id, epmc_id in id_to_epmc.items():
        if local_id in parsed:
            results.append((epmc_id, parsed[local_id]))
        else:
            missing.append((epmc_id, batch_dict[epmc_id]))

    if missing:
        logger.warning(f"批次中 {len(missing)} 条解析失败，单条回退...")
        for epmc_id, title in missing:
            title_zh = await _translate_single(client, epmc_id, title, cfg_ai)
            results.append((epmc_id, title_zh))

    return results


async def run_translation(
    conn: sqlite3.Connection,
    cfg_translate: TranslateConfig,
    cfg_ai: AIConfig,
) -> tuple[int, int]:
    """完整翻译流程，返回 (translated, failed)。"""
    pending = db_mod.fetch_pending_translations(conn)
    if not pending:
        logger.info("没有需要翻译的文章。")
        return 0, 0

    logger.info(f"共 {len(pending)} 篇待翻译（批量大小 {cfg_translate.batch_size}）")

    client = AsyncOpenAI(api_key=cfg_ai.api_key, base_url=cfg_ai.base_url)
    semaphore = asyncio.Semaphore(cfg_translate.concurrency)

    batches = [
        pending[i : i + cfg_translate.batch_size]
        for i in range(0, len(pending), cfg_translate.batch_size)
    ]

    async def process(batch):
        async with semaphore:
            return await _translate_batch(client, batch, cfg_ai)

    tasks = [process(b) for b in batches]
    translated = failed = 0
    buffer: list[tuple[str, str | None]] = []

    for future in tqdm_asyncio.as_completed(tasks, total=len(tasks), desc="翻译进度"):
        batch_results = await future
        buffer.extend(batch_results)
        for _, t in batch_results:
            if t:
                translated += 1
            else:
                failed += 1
        if len(buffer) >= 500:
            db_mod.update_translations(conn, buffer)
            buffer.clear()

    if buffer:
        db_mod.update_translations(conn, buffer)

    return translated, failed

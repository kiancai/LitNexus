"""Europe PMC API 客户端（合并原三个下载脚本）。"""

from __future__ import annotations

import datetime
import json
import logging
import time
from pathlib import Path
from typing import IO, TYPE_CHECKING, Any

import requests
from requests.adapters import HTTPAdapter
from tqdm import tqdm
from urllib3.util.retry import Retry

from litnexus.core.config import Config, DownloadConfig

if TYPE_CHECKING:
    from litnexus.core.workspace import Workspace

logger = logging.getLogger(__name__)

EPMC_API_URL = "https://www.ebi.ac.uk/europepmc/webservices/rest/search"

# 单页请求失败时的额外重试（在 _make_session 的 urllib3 重试之上，覆盖连接/超时/解析失败）
_PAGE_RETRIES = 3
_PAGE_BACKOFF = 2.0


def _make_session() -> requests.Session:
    """创建带指数退避重试的 HTTP Session。"""
    session = requests.Session()
    retry = Retry(
        total=3,
        backoff_factor=1.0,
        status_forcelist=[429, 500, 502, 503, 504],
        allowed_methods=["GET"],
    )
    session.mount("https://", HTTPAdapter(max_retries=retry))
    return session


def build_date_query(days: int) -> str:
    """返回 FIRST_PDATE:[YYYY-MM-DD TO 2099-12-31]。"""
    start = datetime.date.today() - datetime.timedelta(days=days)
    return f"FIRST_PDATE:[{start.strftime('%Y-%m-%d')} TO 2099-12-31]"


def load_query_file(filepath: Path) -> list[str]:
    """从 .txt 文件加载检索式列表，跳过空行和 # 注释行。"""
    if not filepath.exists():
        return []
    lines = []
    with open(filepath, encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if s and not s.startswith("#"):
                lines.append(s)
    return lines


def fetch_articles(
    query: str,
    query_label: str,
    cfg: DownloadConfig,
    out_file: IO[str],
    session: requests.Session | None = None,
    reporter: Any | None = None,
) -> tuple[int, bool]:
    """对单个 query 执行分页抓取，结果写入 out_file（JSONL）。

    返回 (下载总数, 是否完整)。某页多次重试仍失败时记 WARNING、提前结束并把
    第二个返回值置 False，让上层能区分「本来就少」与「抓到一半失败」。
    """
    if session is None:
        session = _make_session()

    cursor_mark = "*"
    page = 1
    total = 0
    complete = True
    pbar: tqdm | None = None
    task_id = None

    while True:
        params = {
            "query": query,
            "format": "json",
            "pageSize": cfg.page_size,
            "resultType": "core",
            "cursorMark": cursor_mark,
            "sort_date": "y",
        }
        data = None
        for attempt in range(_PAGE_RETRIES + 1):
            try:
                resp = session.get(EPMC_API_URL, params=params, timeout=30)
                resp.raise_for_status()
                data = resp.json()
                break
            except requests.RequestException as e:
                if attempt < _PAGE_RETRIES:
                    time.sleep(_PAGE_BACKOFF * (2**attempt))
                    continue
                logger.warning(
                    f"  检索式 '{query_label[:40]}' 第 {page} 页重试 {_PAGE_RETRIES} 次仍失败，"
                    f"结果不完整（已抓 {total} 篇）：{e}"
                )
                complete = False
        if data is None:
            break

        results = data.get("resultList", {}).get("result", [])
        if not results:
            if page == 1:
                logger.info("  找到 0 篇文章。")
            break

        if page == 1:
            hit_count = data.get("hitCount", 0)
            logger.info(f"  找到 {hit_count} 篇文章。")
            if reporter is not None:
                task_id = reporter.add_task(query_label[:42], total=hit_count)
            else:
                pbar = tqdm(
                    total=hit_count,
                    desc=f"  {query_label[:30]}",
                    unit="篇",
                    leave=False,
                )

        for article in results:
            article["query_search_term"] = query_label
            out_file.write(json.dumps(article, ensure_ascii=False) + "\n")

        if reporter is not None:
            reporter.update(task_id, advance=len(results))
        elif pbar is not None:
            pbar.update(len(results))
        total += len(results)

        next_cursor = data.get("nextCursorMark")
        if not next_cursor or next_cursor == cursor_mark:
            break
        cursor_mark = next_cursor
        page += 1
        time.sleep(cfg.request_delay)

    if pbar is not None:
        pbar.close()
    if reporter is not None:
        reporter.complete(task_id)
    return total, complete


def run_download(
    cfg: Config,
    ws: Workspace,
    mode: str = "all",
    days: int | None = None,
    reporter: Any | None = None,
) -> list[Path]:
    """执行下载任务，结果写入 ws.downloads_dir，返回生成的 JSONL 文件路径列表。

    mode: "journals" | "keywords" | "all"
    """
    days = days or cfg.download.days
    date_query = build_date_query(days)
    output_dir = ws.downloads_dir
    output_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    session = _make_session()
    generated: list[Path] = []

    if mode in ("journals", "all"):
        journals = load_query_file(ws.journals_file)
        if journals:
            out_path = output_dir / f"epmc_journals_{timestamp}.jsonl"
            total = 0
            incomplete: list[str] = []
            with open(out_path, "w", encoding="utf-8") as f:
                for journal in journals:
                    logger.info(f"\n--- 抓取期刊：{journal} ---")
                    query = f'JOURNAL:"{journal}" AND {date_query}'
                    n, ok = fetch_articles(query, journal, cfg.download, f, session, reporter)
                    logger.info(f"  完成，下载 {n} 篇")
                    total += n
                    if not ok:
                        incomplete.append(journal)
            logger.info(f"\n期刊下载完成，共 {total} 篇 → {out_path}")
            _warn_incomplete(incomplete)
            generated.append(out_path)
        else:
            logger.warning(f"期刊列表为空或文件不存在：{ws.journals_file}")

    if mode in ("keywords", "all"):
        for kw_file in ws.keywords_files:
            terms = load_query_file(kw_file)
            if not terms:
                logger.warning(f"关键词文件为空或不存在：{kw_file}")
                continue
            stem = kw_file.stem
            out_path = output_dir / f"epmc_{stem}_{timestamp}.jsonl"
            total = 0
            incomplete = []
            with open(out_path, "w", encoding="utf-8") as f:
                for term in terms:
                    label = term[:60] + ("..." if len(term) > 60 else "")
                    logger.info(f"\n--- 抓取检索式：{label} ---")
                    query = f"({term}) AND {date_query}"
                    n, ok = fetch_articles(query, term, cfg.download, f, session, reporter)
                    logger.info(f"  完成，下载 {n} 篇")
                    total += n
                    if not ok:
                        incomplete.append(label)
            logger.info(f"\n关键词下载完成（{kw_file.name}），共 {total} 篇 → {out_path}")
            _warn_incomplete(incomplete)
            generated.append(out_path)

    return generated


def _warn_incomplete(incomplete: list[str]) -> None:
    """对抓取不完整的检索式发出醒目告警（默认日志级别即可见）。"""
    if not incomplete:
        return
    shown = ", ".join(incomplete[:5])
    more = f" 等 {len(incomplete)} 个" if len(incomplete) > 5 else ""
    logger.warning(f"⚠ {len(incomplete)} 个检索式抓取不完整（网络失败）：{shown}{more}")

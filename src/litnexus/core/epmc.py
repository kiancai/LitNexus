"""Europe PMC API 客户端（合并原三个下载脚本）。"""

from __future__ import annotations

import datetime
import json
import time
from pathlib import Path
from typing import IO

import requests

from litnexus.core.config import Config, DownloadConfig

EPMC_API_URL = "https://www.ebi.ac.uk/europepmc/webservices/rest/search"


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
) -> int:
    """对单个 query 执行分页抓取，结果写入 out_file（JSONL），返回下载总数。"""
    cursor_mark = "*"
    page = 1
    total = 0

    while True:
        params = {
            "query": query,
            "format": "json",
            "pageSize": cfg.page_size,
            "resultType": "core",
            "cursorMark": cursor_mark,
            "sort_date": "y",
        }
        try:
            resp = requests.get(EPMC_API_URL, params=params, timeout=30)
            resp.raise_for_status()
            data = resp.json()
        except requests.RequestException as e:
            print(f"  API 请求失败：{e}")
            break

        results = data.get("resultList", {}).get("result", [])
        if not results:
            if page == 1:
                print("  找到 0 篇文章。")
            break

        if page == 1:
            print(f"  找到 {data.get('hitCount', 0)} 篇文章。")
        print(f"  写入第 {page} 页（{len(results)} 篇）...")

        for article in results:
            article["query_search_term"] = query_label
            out_file.write(json.dumps(article, ensure_ascii=False) + "\n")

        total += len(results)
        next_cursor = data.get("nextCursorMark")
        if not next_cursor or next_cursor == cursor_mark:
            break
        cursor_mark = next_cursor
        page += 1
        time.sleep(cfg.request_delay)

    return total


def run_download(
    cfg: Config,
    output_dir: Path,
    mode: str = "all",
    days: int | None = None,
) -> list[Path]:
    """执行下载任务，返回生成的 JSONL 文件路径列表。

    mode: "journals" | "keywords" | "all"
    """
    days = days or cfg.download.days
    date_query = build_date_query(days)
    output_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    generated: list[Path] = []

    if mode in ("journals", "all"):
        journals = load_query_file(cfg.paths.journals_file)
        if journals:
            out_path = output_dir / f"epmc_journals_{timestamp}.jsonl"
            total = 0
            with open(out_path, "w", encoding="utf-8") as f:
                for journal in journals:
                    print(f"\n--- 抓取期刊：{journal} ---")
                    query = f'JOURNAL:"{journal}" AND {date_query}'
                    n = fetch_articles(query, journal, cfg.download, f)
                    print(f"  完成，下载 {n} 篇")
                    total += n
            print(f"\n期刊下载完成，共 {total} 篇 → {out_path}")
            generated.append(out_path)
        else:
            print(f"期刊列表为空或文件不存在：{cfg.paths.journals_file}")

    if mode in ("keywords", "all"):
        for kw_file in cfg.paths.keywords_files:
            terms = load_query_file(kw_file)
            if not terms:
                print(f"关键词文件为空或不存在：{kw_file}")
                continue
            stem = kw_file.stem
            out_path = output_dir / f"epmc_{stem}_{timestamp}.jsonl"
            total = 0
            with open(out_path, "w", encoding="utf-8") as f:
                for term in terms:
                    label = term[:60] + ("..." if len(term) > 60 else "")
                    print(f"\n--- 抓取检索式：{label} ---")
                    query = f"({term}) AND {date_query}"
                    n = fetch_articles(query, term, cfg.download, f)
                    print(f"  完成，下载 {n} 篇")
                    total += n
            print(f"\n关键词下载完成（{kw_file.name}），共 {total} 篇 → {out_path}")
            generated.append(out_path)

    return generated

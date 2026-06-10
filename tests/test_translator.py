"""翻译模块测试（mock AsyncOpenAI，不发真实请求）。

回归 P1 修复：RateLimitError 有界退避后放弃（不无限挂起）；content 为 None 不崩溃。
"""

from __future__ import annotations

import json

import httpx
from openai import RateLimitError

from litnexus.core import db as db_mod
from litnexus.core import translator as trans_mod
from litnexus.core.config import AIConfig, TranslateConfig

_AI = AIConfig(api_key="k", base_url="https://x/v1", model="m")
_TR = TranslateConfig(batch_size=30, concurrency=5)


def _resp(content):
    msg = type("M", (), {"content": content})()
    return type("R", (), {"choices": [type("C", (), {"message": msg})()]})()


def _fake_async_openai(create_fn):
    class _Completions:
        async def create(self, **kwargs):
            return create_fn(**kwargs)

    class _Chat:
        def __init__(self):
            self.completions = _Completions()

    class _AsyncOpenAI:
        def __init__(self, *args, **kwargs):
            self.chat = _Chat()

    return _AsyncOpenAI


def _rate_limit_error() -> RateLimitError:
    req = httpx.Request("POST", "https://x/v1/chat/completions")
    return RateLimitError("rate limited", response=httpx.Response(429, request=req), body=None)


def _insert_titles(conn, n=2):
    db_mod.insert_articles(
        conn,
        [
            {"epmc_id": f"E{i}", "pmid": str(i), "doi": f"d{i}", "source": "MED",
             "title": f"Title {i}", "pub_year": 2026}
            for i in range(1, n + 1)
        ],
    )


async def test_translate_success(ws_cfg, monkeypatch):
    ws, cfg = ws_cfg
    conn = db_mod.get_connection(ws.db_path, cfg)
    _insert_titles(conn, 2)

    def create_fn(**kwargs):
        payload = json.loads(kwargs["messages"][1]["content"])
        out = [{"id": item["id"], "title_zh": f"译{item['id']}"} for item in payload]
        return _resp(json.dumps(out, ensure_ascii=False))

    monkeypatch.setattr(trans_mod, "AsyncOpenAI", _fake_async_openai(create_fn))
    translated, failed = await trans_mod.run_translation(conn, _TR, _AI)

    assert (translated, failed) == (2, 0)
    rows = {r[0]: r[1] for r in conn.execute("SELECT epmc_id, title_zh FROM articles").fetchall()}
    assert rows == {"E1": "译1", "E2": "译2"}
    conn.close()


async def test_translate_rate_limit_gives_up(ws_cfg, monkeypatch):
    ws, cfg = ws_cfg
    conn = db_mod.get_connection(ws.db_path, cfg)
    _insert_titles(conn, 1)

    async def _nosleep(*a, **k):
        pass

    monkeypatch.setattr(trans_mod.asyncio, "sleep", _nosleep)
    calls = {"n": 0}

    def create_fn(**kwargs):
        calls["n"] += 1
        raise _rate_limit_error()

    monkeypatch.setattr(trans_mod, "AsyncOpenAI", _fake_async_openai(create_fn))
    translated, failed = await trans_mod.run_translation(conn, _TR, _AI)

    assert (translated, failed) == (0, 1)
    # title_zh 保持 NULL（下次自然重试），且重试有上限、不会无限挂起
    assert conn.execute("SELECT title_zh FROM articles WHERE epmc_id='E1'").fetchone()[0] is None
    assert calls["n"] == trans_mod._MAX_RETRIES + 1
    conn.close()


async def test_translate_none_content(ws_cfg, monkeypatch):
    ws, cfg = ws_cfg
    conn = db_mod.get_connection(ws.db_path, cfg)
    _insert_titles(conn, 1)
    monkeypatch.setattr(trans_mod, "AsyncOpenAI", _fake_async_openai(lambda **k: _resp(None)))

    translated, failed = await trans_mod.run_translation(conn, _TR, _AI)

    assert (translated, failed) == (0, 1)
    assert conn.execute("SELECT title_zh FROM articles WHERE epmc_id='E1'").fetchone()[0] is None
    conn.close()

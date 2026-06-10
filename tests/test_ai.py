"""AI 分类模块测试（mock OpenAI，不发真实请求）。

重点回归 P0 修复：分类失败的文章不写库（_ans 保持 NULL），下次运行自动重试。
"""

from __future__ import annotations

import json

import httpx
from openai import RateLimitError

from litnexus.core import classifier as cls_mod
from litnexus.core import db as db_mod
from litnexus.core.config import AIConfig


def _rate_limit_error() -> RateLimitError:
    req = httpx.Request("POST", "https://x/v1/chat/completions")
    return RateLimitError("rate limited", response=httpx.Response(429, request=req), body=None)

# ── mock OpenAI 客户端 ────────────────────────────────────────────────────────


class _Resp:
    def __init__(self, content: str) -> None:
        self.choices = [type("C", (), {"message": type("M", (), {"content": content})()})()]


def _fake_openai(create_fn):
    """返回一个仿冒的 OpenAI 类，其 chat.completions.create 调用 create_fn(**kwargs)。"""

    class _Completions:
        def create(self, **kwargs):
            return create_fn(**kwargs)

    class _Chat:
        completions = _Completions()

    class _OpenAI:
        def __init__(self, *args, **kwargs):
            self.chat = _Chat()

    return _OpenAI


def _answers_json(q1="是", q2="否") -> str:
    return json.dumps(
        {"q1": {"answer": q1, "reason": "r1"}, "q2": {"answer": q2, "reason": "r2"}},
        ensure_ascii=False,
    )


def _insert(conn, epmc_id="E1"):
    db_mod.insert_articles(
        conn,
        [{
            "epmc_id": epmc_id, "pmid": epmc_id, "doi": epmc_id, "source": "MED",
            "title": "Some title", "abstract": "Some abstract", "pub_year": 2026,
        }],
    )


_AI = AIConfig(api_key="k", base_url="https://x/v1", model="m")


# ── 成功路径 ──────────────────────────────────────────────────────────────────


def test_classify_writes_answers(ws_cfg, monkeypatch):
    ws, cfg = ws_cfg
    conn = db_mod.get_connection(ws.db_path, cfg)
    _insert(conn)
    monkeypatch.setattr(cls_mod, "OpenAI", _fake_openai(lambda **k: _Resp(_answers_json())))

    processed, failed = cls_mod.run_classification(conn, cfg.classify, _AI)

    assert (processed, failed) == (1, 0)
    row = dict(
        conn.execute("SELECT q1_ans, q1_rea, q2_ans FROM articles WHERE epmc_id='E1'").fetchone()
    )
    assert row["q1_ans"] == "是"
    assert row["q1_rea"] == "r1"
    assert row["q2_ans"] == "否"
    conn.close()


# ── 失败可重试（P0 回归）──────────────────────────────────────────────────────


def test_classify_failure_keeps_null_and_is_retryable(ws_cfg, monkeypatch):
    ws, cfg = ws_cfg
    conn = db_mod.get_connection(ws.db_path, cfg)
    _insert(conn)

    # 第一轮：API 持续失败
    def boom(**kwargs):
        raise RuntimeError("rate limited")

    monkeypatch.setattr(cls_mod, "OpenAI", _fake_openai(boom))
    processed, failed = cls_mod.run_classification(conn, cfg.classify, _AI)
    assert (processed, failed) == (0, 1)

    # 失败不得写入 "API错误"，_ans 须保持 NULL
    row = dict(conn.execute("SELECT q1_ans, q2_ans FROM articles WHERE epmc_id='E1'").fetchone())
    assert row["q1_ans"] is None and row["q2_ans"] is None
    # 仍是待分类，可被下次运行捡起
    assert len(db_mod.fetch_pending_classification(conn, cfg.classify.questions)) == 1

    # 第二轮：API 恢复正常 → 成功补齐
    recovered = _fake_openai(lambda **k: _Resp(_answers_json("是", "是")))
    monkeypatch.setattr(cls_mod, "OpenAI", recovered)
    processed2, failed2 = cls_mod.run_classification(conn, cfg.classify, _AI)
    assert (processed2, failed2) == (1, 0)
    row2 = dict(conn.execute("SELECT q1_ans, q2_ans FROM articles WHERE epmc_id='E1'").fetchone())
    assert row2["q1_ans"] == "是" and row2["q2_ans"] == "是"
    conn.close()


# ── 缺标题摘要 → N/A（终态）────────────────────────────────────────────────────


def test_classify_no_text_marks_na(ws_cfg, monkeypatch):
    ws, cfg = ws_cfg
    conn = db_mod.get_connection(ws.db_path, cfg)
    # title/abstract 为空白，但非 NULL（否则不会被选为待分类）
    db_mod.insert_articles(
        conn,
        [{"epmc_id": "E1", "pmid": "1", "doi": "d1", "source": "MED",
          "title": "   ", "abstract": "  ", "pub_year": 2026}],
    )

    def boom(**kwargs):  # 不该被调用
        raise AssertionError("缺文本时不应调用 API")

    monkeypatch.setattr(cls_mod, "OpenAI", _fake_openai(boom))
    processed, failed = cls_mod.run_classification(conn, cfg.classify, _AI)

    assert (processed, failed) == (1, 0)
    row = dict(conn.execute("SELECT q1_ans FROM articles WHERE epmc_id='E1'").fetchone())
    assert row["q1_ans"] == "N/A"
    conn.close()


# ── 限流退避（P1）─────────────────────────────────────────────────────────────


def test_classify_rate_limit_then_success(ws_cfg, monkeypatch):
    ws, cfg = ws_cfg
    conn = db_mod.get_connection(ws.db_path, cfg)
    _insert(conn)
    monkeypatch.setattr(cls_mod.time, "sleep", lambda *a: None)  # 不真的等待

    state = {"n": 0}

    def create_fn(**kwargs):
        state["n"] += 1
        if state["n"] <= 2:  # 前两次限流
            raise _rate_limit_error()
        return _Resp(_answers_json())

    monkeypatch.setattr(cls_mod, "OpenAI", _fake_openai(create_fn))
    processed, failed = cls_mod.run_classification(conn, cfg.classify, _AI)

    assert (processed, failed) == (1, 0)
    assert state["n"] == 3  # 2 次限流重试 + 1 次成功
    row = dict(conn.execute("SELECT q1_ans FROM articles WHERE epmc_id='E1'").fetchone())
    assert row["q1_ans"] == "是"
    conn.close()


# ── content 为 None 不崩溃（P1）────────────────────────────────────────────────


def test_classify_none_content_is_failure_not_crash(ws_cfg, monkeypatch):
    ws, cfg = ws_cfg
    conn = db_mod.get_connection(ws.db_path, cfg)
    _insert(conn)
    monkeypatch.setattr(cls_mod, "OpenAI", _fake_openai(lambda **k: _Resp(None)))

    processed, failed = cls_mod.run_classification(conn, cfg.classify, _AI)

    assert (processed, failed) == (0, 1)  # 解析为空 → 失败、不写库
    row = dict(conn.execute("SELECT q1_ans FROM articles WHERE epmc_id='E1'").fetchone())
    assert row["q1_ans"] is None  # 可重试
    conn.close()

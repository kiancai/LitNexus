"""Europe PMC 客户端测试（mock session，P1：分页失败可见性）。"""

from __future__ import annotations

import io

import requests

from litnexus.core import epmc as epmc_mod
from litnexus.core.config import DownloadConfig

_CFG = DownloadConfig(page_size=1000, request_delay=0.0)


class _Resp:
    def __init__(self, payload):
        self._p = payload

    def raise_for_status(self):
        pass

    def json(self):
        return self._p


def _page(results, next_cursor=None, hit=None):
    d = {"resultList": {"result": results}}
    if hit is not None:
        d["hitCount"] = hit
    if next_cursor is not None:
        d["nextCursorMark"] = next_cursor
    return d


def test_fetch_articles_complete():
    pages = iter([
        _page([{"id": "A"}, {"id": "B"}], next_cursor="c2", hit=2),
        _page([]),  # 空结果 → 正常结束
    ])

    class _S:
        def get(self, *a, **k):
            return _Resp(next(pages))

    out = io.StringIO()
    total, complete = epmc_mod.fetch_articles("q", "label", _CFG, out, session=_S())

    assert (total, complete) == (2, True)
    assert out.getvalue().strip().count("\n") == 1  # 2 行 → 1 个换行分隔


def test_fetch_articles_incomplete_on_persistent_failure(monkeypatch):
    monkeypatch.setattr(epmc_mod.time, "sleep", lambda *a: None)

    class _S:
        def __init__(self):
            self.n = 0

        def get(self, *a, **k):
            self.n += 1
            if self.n == 1:
                return _Resp(_page([{"id": "A"}, {"id": "B"}], next_cursor="c2", hit=2))
            raise requests.ConnectionError("boom")

    out = io.StringIO()
    total, complete = epmc_mod.fetch_articles("q", "label", _CFG, out, session=_S())

    assert total == 2          # 第一页已抓到的
    assert complete is False    # 第二页持续失败 → 标记不完整，但不抛异常

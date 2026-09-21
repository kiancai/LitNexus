"""Keep published URLs working after the documentation reorganization."""

import html
import json
import posixpath
from pathlib import Path

REDIRECTS = {
    "architecture/overview": "develop/architecture",
    "architecture/platforms": "develop/platforms",
    "architecture/database": "reference/database",
    "architecture/pipeline": "reference/pipeline",
    "architecture/workspace": "reference/workspace",
    "product/overview": "reference/product",
    "product/scope": "reference/scope",
    "roadmap": "develop/roadmap",
    "backlog": "develop/backlog",
    "guide/quickstart": "start/quickstart",
}


def on_post_build(config, **kwargs):
    # i18n finishes both language trees before this hook runs.
    root = Path(config["site_dir"])
    for language_root in (root, root / "en"):
        if language_root.is_dir():
            write_redirects(language_root)


def write_redirects(root):
    for old, new in REDIRECTS.items():
        target = root / new / "index.html"
        if not target.is_file():
            raise RuntimeError(f"Redirect target missing: {target}")
        relative = posixpath.relpath(new, old) + "/"
        destination = root / old / "index.html"
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(
            '<!doctype html><html><head><meta charset="utf-8">'
            '<meta name="robots" content="noindex">'
            '<title>Page moved · LitNexus</title>'
            '<script>location.replace(' + json.dumps(relative)
            + '+location.search+location.hash);</script>'
            '<noscript><meta http-equiv="refresh" content="0;url='
            + html.escape(relative, quote=True) + '"></noscript>'
            '</head><body><p>页面已迁移 / Page moved: <a href="'
            + html.escape(relative, quote=True)
            + '">继续 / Continue</a></p></body></html>\n',
            encoding="utf-8",
        )

"""Check the built site's local links, language parity and legacy redirects."""

from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urljoin, urlsplit

from docs_redirects import REDIRECTS

ROOT = Path("site").resolve()
BASE = "https://kiancai.github.io/LitNexus/"


class Page(HTMLParser):
    def __init__(self, text):
        super().__init__()
        self.links = []
        self.ids = set()
        self.feed(text)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if attrs.get("id"):
            self.ids.add(attrs["id"])
        if tag in ("a", "link") and attrs.get("href"):
            self.links.append(attrs["href"])
        if tag in ("img", "script") and attrs.get("src"):
            self.links.append(attrs["src"])


def main():
    pages = {
        path: Page(path.read_text(encoding="utf-8"))
        for path in ROOT.rglob("*.html")
    }
    errors = []
    if not pages:
        raise SystemExit("Build the site before checking it")
    for path, page in pages.items():
        relative = path.relative_to(ROOT).as_posix()
        # The 404 template is served at arbitrary URLs; relative links vary.
        if path.name == "404.html":
            continue
        url = BASE + (relative[:-10] if relative.endswith("index.html") else relative)
        for link in page.links:
            parsed = urlsplit(urljoin(url, link))
            if parsed.netloc != "kiancai.github.io" or not parsed.path.startswith("/LitNexus/"):
                continue
            target = ROOT / unquote(parsed.path[len("/LitNexus/"):])
            if target.is_dir():
                target /= "index.html"
            if not target.is_file():
                errors.append(f"{relative}: missing {link}")
            elif parsed.fragment and target in pages:
                if unquote(parsed.fragment) not in pages[target].ids:
                    errors.append(f"{relative}: missing anchor {link}")

    for path in Path("docs").rglob("*.md"):
        if path.name.endswith(".en.md") or path.stem == "showcase":
            continue
        if not path.with_suffix(".en.md").is_file():
            errors.append(f"Missing English source: {path}")
        text = path.read_text(encoding="utf-8")
        if "<!-- TODO" in text or "步骤1" in text or "步骤2" in text:
            errors.append(f"Unfinished guide: {path}")

    for prefix in ("", "en/"):
        for old, new in REDIRECTS.items():
            path = ROOT / prefix / old / "index.html"
            if path not in pages or "location.replace" not in path.read_text(encoding="utf-8"):
                errors.append(f"Missing redirect: {prefix}{old}")
            if not (ROOT / prefix / new / "index.html").is_file():
                errors.append(f"Missing redirect target: {prefix}{new}")

    if errors:
        raise SystemExit("\n".join(sorted(set(errors))))
    print(f"Checked {len(pages)} HTML pages: local links, anchors, translations and 20 redirects OK")


if __name__ == "__main__":
    main()

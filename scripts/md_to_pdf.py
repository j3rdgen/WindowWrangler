#!/usr/bin/env python3
"""Convert Window Wrangler docs (Markdown) to standalone HTML + PDF.

For each input .md file, writes a sibling .html (styled, self-contained) and
.pdf (rendered by headless Chrome from the HTML).
"""
import subprocess
import sys
from pathlib import Path

import markdown


CSS = """
:root {
    color-scheme: light;
    --fg: #1c1c1e;
    --fg-muted: #4a4a4c;
    --accent: #0b6cff;
    --code-bg: #f5f5f7;
    --border: #d6d6da;
    --table-alt: #fafafa;
}
html { font-size: 15px; }
body {
    font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, sans-serif;
    color: var(--fg);
    background: white;
    max-width: 780px;
    margin: 3rem auto;
    padding: 0 2rem;
    line-height: 1.6;
    -webkit-font-smoothing: antialiased;
    -moz-osx-font-smoothing: grayscale;
}
h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin-top: 2em; margin-bottom: 0.5em; font-weight: 600; }
h1 { font-size: 2rem; margin-top: 0; padding-bottom: 0.4em; border-bottom: 1px solid var(--border); }
h2 { font-size: 1.5rem; padding-bottom: 0.3em; border-bottom: 1px solid var(--border); }
h3 { font-size: 1.2rem; }
h4 { font-size: 1.05rem; }
p { margin: 0.9em 0; }
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }
strong { font-weight: 600; }
em { font-style: italic; }
code {
    font-family: "SF Mono", Menlo, Monaco, Consolas, "Courier New", monospace;
    background: var(--code-bg);
    padding: 0.15em 0.35em;
    border-radius: 3px;
    font-size: 0.88em;
}
pre {
    background: var(--code-bg);
    padding: 1em;
    border-radius: 6px;
    overflow-x: auto;
    line-height: 1.5;
    border: 1px solid var(--border);
}
pre code {
    background: none;
    padding: 0;
    border-radius: 0;
    font-size: 0.85em;
}
blockquote {
    margin: 1em 0;
    padding: 0.5em 1em;
    border-left: 4px solid var(--border);
    color: var(--fg-muted);
    background: var(--table-alt);
}
ul, ol { padding-left: 1.5em; margin: 0.9em 0; }
li { margin: 0.25em 0; }
table {
    width: 100%;
    border-collapse: collapse;
    margin: 1em 0;
    font-size: 0.92em;
}
th, td {
    padding: 0.5em 0.75em;
    border: 1px solid var(--border);
    text-align: left;
    vertical-align: top;
}
th {
    background: var(--code-bg);
    font-weight: 600;
}
tr:nth-child(even) td { background: var(--table-alt); }
hr {
    border: none;
    border-top: 1px solid var(--border);
    margin: 2em 0;
}
kbd {
    font-family: "SF Mono", Menlo, monospace;
    background: white;
    border: 1px solid var(--border);
    border-bottom-width: 2px;
    border-radius: 3px;
    padding: 0.1em 0.4em;
    font-size: 0.85em;
}
/* Print-friendly */
@media print {
    body { max-width: 100%; margin: 0; padding: 1.5cm; }
    pre, code { background: #f5f5f7 !important; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    th { background: #f5f5f7 !important; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    tr:nth-child(even) td { background: #fafafa !important; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    h1, h2 { page-break-after: avoid; }
    pre, table, blockquote { page-break-inside: avoid; }
}
"""

HTML_TEMPLATE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{title}</title>
<style>{css}</style>
</head>
<body>
{body}
</body>
</html>
"""


def md_to_html(md_path: Path, html_path: Path) -> None:
    md_source = md_path.read_text(encoding="utf-8")
    body = markdown.markdown(
        md_source,
        extensions=[
            "fenced_code",
            "tables",
            "toc",
            "sane_lists",
        ],
    )
    title = md_path.stem
    for line in md_source.splitlines():
        s = line.strip()
        if s.startswith("# "):
            title = s[2:].strip()
            break
    html = HTML_TEMPLATE.format(title=title, css=CSS, body=body)
    html_path.write_text(html, encoding="utf-8")


def html_to_pdf(html_path: Path, pdf_path: Path) -> None:
    chrome_bin = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    file_url = f"file://{html_path.resolve()}"
    subprocess.run(
        [
            chrome_bin,
            "--headless=new",
            "--no-pdf-header-footer",
            "--disable-gpu",
            f"--print-to-pdf={pdf_path.resolve()}",
            file_url,
        ],
        check=True,
        capture_output=True,
    )


def convert(md_path: Path) -> None:
    html_path = md_path.with_suffix(".html")
    pdf_path = md_path.with_suffix(".pdf")
    print(f"→ {md_path.name}")
    md_to_html(md_path, html_path)
    print(f"  wrote {html_path.name}")
    html_to_pdf(html_path, pdf_path)
    print(f"  wrote {pdf_path.name}")


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: md_to_pdf.py <file.md> [<file.md> ...]", file=sys.stderr)
        return 1
    for arg in sys.argv[1:]:
        md_path = Path(arg)
        if not md_path.exists() or md_path.suffix != ".md":
            print(f"skip: {md_path} (not a .md file)", file=sys.stderr)
            continue
        convert(md_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())

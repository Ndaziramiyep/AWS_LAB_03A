"""Build the discovery report PDF and the architecture diagram (SVG + PNG) with headless Chrome/Edge.

Usage:  python docs/report/build.py
Output: docs/discovery-report.pdf, docs/architecture.svg, docs/architecture.png
"""
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent          # docs/report
DOCS = HERE.parent                              # docs/

BROWSERS = [                                    # first one found is used
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    "/usr/bin/google-chrome", "/usr/bin/chromium",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
]


def browser():
    """Path of an installed Chromium-based browser."""
    for b in BROWSERS:
        if Path(b).exists():
            return b
    found = shutil.which("chrome") or shutil.which("msedge") or shutil.which("chromium")
    if not found:
        raise SystemExit("Chrome or Edge is required to render the PDF")
    return found


def run(args):
    """Run the browser headless with a throwaway profile."""
    with tempfile.TemporaryDirectory() as profile:
        subprocess.run([browser(), "--headless=new", "--disable-gpu", "--no-first-run",
                        f"--user-data-dir={profile}", *args], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    icons = (HERE / "icons.svg").read_text(encoding="utf-8")            # shared icon sprite
    diagram = (HERE / "diagram.svg").read_text(encoding="utf-8")        # diagram template

    # 1. Standalone diagram SVG (icons embedded) for docs/ and draw.io import.
    svg = diagram.replace("{{ICONS}}", icons)
    (DOCS / "architecture.svg").write_text(svg, encoding="utf-8")

    # 2. PNG of the diagram at 2x scale.
    png_html = HERE / "_diagram.html"
    png_html.write_text(f"<!doctype html><meta charset='utf-8'><style>html,body{{margin:0;background:#fff}}</style>{svg}",
                        encoding="utf-8")
    run([f"--screenshot={DOCS / 'architecture.png'}", "--window-size=1200,720",
         "--force-device-scale-factor=2", "--hide-scrollbars", png_html.as_uri()])
    png_html.unlink()

    # 3. Report PDF (icons defined once, diagram inlined without a second copy of the sprite).
    html = (HERE / "report.html").read_text(encoding="utf-8")
    html = html.replace("{{ICONS}}", icons).replace("{{DIAGRAM}}", diagram.replace("{{ICONS}}", ""))
    built = HERE / "_report.html"
    built.write_text(html, encoding="utf-8")
    run(["--no-pdf-header-footer", f"--print-to-pdf={DOCS / 'discovery-report.pdf'}", built.as_uri()])
    built.unlink()
    print("wrote", DOCS / "discovery-report.pdf", DOCS / "architecture.svg", DOCS / "architecture.png", sep="\n  ")


if __name__ == "__main__":
    main()

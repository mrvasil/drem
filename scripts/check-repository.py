#!/usr/bin/env python3
"""Offline publication checks. Report paths, never matched secret values."""
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
TOP_LEVEL = {"Sources", "Tests", "scripts", "Resources", "docs", ".github"}
TEXT_SUFFIXES = {".swift", ".py", ".sh", ".md", ".yml", ".yaml", ".svg", ".plist"}
SECRET_PATTERNS = [
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(r"gh[pousr]_[A-Za-z0-9]{30,}"),
    re.compile(r"github_pat_[A-Za-z0-9_]{40,}"),
    re.compile(r"sk-(?:proj-|ant-)?[A-Za-z0-9_-]{30,}"),
]
errors = []
files = [p for p in ROOT.iterdir() if p.is_file()]
for name in TOP_LEVEL:
    directory = ROOT / name
    if directory.exists():
        files.extend(p for p in directory.rglob("*") if p.is_file() and "__pycache__" not in p.parts)

for path in sorted(files):
    relative = path.relative_to(ROOT)
    if path.stat().st_size > 5 * 1024 * 1024:
        errors.append(f"{relative}: unexpected file larger than 5 MiB")
    if path.suffix not in TEXT_SUFFIXES and path.name not in {"Makefile", ".gitignore", ".gitattributes", ".editorconfig", "CODEOWNERS"}:
        continue
    text = path.read_text(encoding="utf-8")
    if any(pattern.search(text) for pattern in SECRET_PATTERNS):
        errors.append(f"{relative}: possible credential; inspect locally before publication")
    if not text.endswith("\n"):
        errors.append(f"{relative}: missing final newline")
    if path.suffix == ".md":
        targets = re.findall(r"\]\(([^)]+)\)", text)
        targets += re.findall(r'(?:src|srcset)="([^"]+)"', text)
        for target in targets:
            if target.startswith(("http:", "https:", "mailto:", "#")):
                continue
            target = unquote(target.split("#", 1)[0])
            if target and not (path.parent / target).exists():
                errors.append(f"{relative}: broken local link {target}")
    if path.suffix == ".svg":
        try:
            ET.fromstring(text)
        except ET.ParseError as error:
            errors.append(f"{relative}: invalid SVG: {error}")

for required in ["LICENSE", "THIRD_PARTY_NOTICES.md", "README.md", "CONTRIBUTING.md", "SECURITY.md", ".github/workflows/ci.yml"]:
    if not (ROOT / required).is_file():
        errors.append(f"missing {required}")

if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)

for script in (ROOT / "scripts").glob("*.sh"):
    subprocess.run(["zsh", "-n", str(script)], check=True)
print(f"Repository checks passed ({len(files)} source/documentation/assets files).")

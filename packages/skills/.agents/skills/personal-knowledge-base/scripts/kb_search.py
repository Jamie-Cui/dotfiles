#!/usr/bin/env python3
"""Search and suggest targets in Jamie's personal Org knowledge base."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from uuid import uuid4


DEFAULT_ROOT = Path(os.environ.get("PERSONAL_KB_ROOT", "/home/jamie/opt/org-root")).expanduser()
DEFAULT_SCOPES = ("roam", "projects", "deft", "journal", "README.org", "AGENTS.md")
TEXT_SUFFIXES = {".org", ".md", ".txt"}
EXCLUDED_PARTS = {
    ".git",
    ".agent-shell",
    ".agents",
    ".codex",
    ".stfolder",
    "auto",
    "ltximg",
    "node_modules",
    "__pycache__",
    "pdf",
    "archive",
}
CJK_RE = re.compile(r"[\u3400-\u9fff]+")
WORD_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_+.-]*")


@dataclass
class Match:
    path: Path
    relpath: str
    title: str
    score: float
    snippets: list[tuple[int, str]]


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return ""


def title_for(path: Path, text: str) -> str:
    for line in text.splitlines()[:80]:
        stripped = line.strip()
        lower = stripped.lower()
        if lower.startswith("#+title:"):
            return stripped.split(":", 1)[1].strip()
        if stripped.startswith("* "):
            return stripped.lstrip("*").strip()
        if stripped.startswith("# "):
            return stripped[2:].strip()
    return path.stem


def query_terms(query: str) -> list[str]:
    terms: list[str] = []
    for token in WORD_RE.findall(query):
        if len(token) >= 2:
            terms.append(token.lower())
    for chunk in CJK_RE.findall(query):
        if len(chunk) <= 8:
            terms.append(chunk)
        else:
            terms.extend(chunk[i : i + 4] for i in range(0, len(chunk) - 3))
    seen = set()
    result = []
    for term in terms:
        if term not in seen:
            seen.add(term)
            result.append(term)
    return result


def should_skip(path: Path, root: Path, include_external: bool) -> bool:
    try:
        rel = path.relative_to(root)
    except ValueError:
        return True
    parts = set(rel.parts)
    if "external" in parts and not include_external:
        return True
    return bool(parts & EXCLUDED_PARTS)


def iter_files(root: Path, scopes: list[str], include_external: bool) -> list[Path]:
    files: list[Path] = []
    for scope in scopes:
        base = root / scope
        if not base.exists():
            continue
        if base.is_file():
            candidates = [base]
        else:
            candidates = [p for p in base.rglob("*") if p.is_file()]
        for path in candidates:
            if path.suffix.lower() not in TEXT_SUFFIXES:
                continue
            if should_skip(path, root, include_external):
                continue
            files.append(path)
    return sorted(set(files))


def score_text(query: str, terms: list[str], relpath: str, title: str, text: str) -> float:
    if not terms:
        return 0.0
    haystack = text.lower()
    title_l = title.lower()
    path_l = relpath.lower()
    score = 0.0
    if query and query.lower() in haystack:
        score += 25.0
    for term in terms:
        body_hits = haystack.count(term.lower())
        if body_hits:
            score += min(body_hits, 20)
        if term.lower() in title_l:
            score += 12.0
        if term.lower() in path_l:
            score += 4.0
    return score


def snippets_for(text: str, terms: list[str], max_snippets: int) -> list[tuple[int, str]]:
    if not terms:
        return []
    results: list[tuple[int, str]] = []
    lowered_terms = [t.lower() for t in terms]
    for lineno, line in enumerate(text.splitlines(), start=1):
        lower = line.lower()
        if any(term in lower for term in lowered_terms):
            compact = re.sub(r"\s+", " ", line).strip()
            if len(compact) > 220:
                compact = compact[:217] + "..."
            results.append((lineno, compact))
            if len(results) >= max_snippets:
                break
    return results


def search(root: Path, query: str, scopes: list[str], limit: int, include_external: bool) -> list[Match]:
    terms = query_terms(query)
    matches: list[Match] = []
    for path in iter_files(root, scopes, include_external):
        text = read_text(path)
        relpath = str(path.relative_to(root))
        title = title_for(path, text)
        score = score_text(query, terms, relpath, title, text)
        if score <= 0:
            continue
        matches.append(
            Match(
                path=path,
                relpath=relpath,
                title=title,
                score=score,
                snippets=snippets_for(text, terms, 3),
            )
        )
    matches.sort(key=lambda m: (-m.score, m.relpath))
    return matches[:limit]


def print_matches(matches: list[Match], as_json: bool) -> None:
    if as_json:
        print(
            json.dumps(
                [
                    {
                        "path": str(m.path),
                        "relpath": m.relpath,
                        "title": m.title,
                        "score": m.score,
                        "snippets": [{"line": line, "text": text} for line, text in m.snippets],
                    }
                    for m in matches
                ],
                ensure_ascii=False,
                indent=2,
            )
        )
        return
    if not matches:
        print("No matching notes found.")
        return
    for index, match in enumerate(matches, start=1):
        print(f"{index}. {match.relpath}  score={match.score:.1f}")
        print(f"   title: {match.title}")
        for line, text in match.snippets:
            print(f"   L{line}: {text}")


def suggest(root: Path, text: str, scopes: list[str], limit: int, include_external: bool, as_json: bool) -> None:
    terms = query_terms(text)
    query = " ".join(terms[:10]) if terms else text[:120]
    matches = search(root, query, scopes, limit, include_external)
    now = datetime.now()
    fallback = root / "roam" / f"{now:%Y-%m-%dt%H%M}.org"
    payload = {
        "query": query,
        "strong_existing_target": str(matches[0].path) if matches and matches[0].score >= 18 else None,
        "new_roam_fallback": str(fallback),
        "new_note_template": {
            "id": str(uuid4()),
            "title": "replace with concise title",
            "filetags": ":replace:",
        },
        "matches": [
            {
                "path": str(m.path),
                "relpath": m.relpath,
                "title": m.title,
                "score": m.score,
                "snippets": [{"line": line, "text": snippet} for line, snippet in m.snippets],
            }
            for m in matches
        ],
    }
    if as_json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return
    print(f"query: {payload['query']}")
    if payload["strong_existing_target"]:
        print(f"strong existing target: {payload['strong_existing_target']}")
    else:
        print("strong existing target: none")
    print(f"new roam fallback: {payload['new_roam_fallback']}")
    print(f"new note id: {payload['new_note_template']['id']}")
    print()
    print_matches(matches, False)


def recent(root: Path, scopes: list[str], limit: int, include_external: bool, as_json: bool) -> None:
    items = []
    for path in iter_files(root, scopes, include_external):
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue
        text = read_text(path)
        items.append(
            {
                "path": str(path),
                "relpath": str(path.relative_to(root)),
                "title": title_for(path, text),
                "mtime": datetime.fromtimestamp(mtime).isoformat(timespec="seconds"),
            }
        )
    items.sort(key=lambda item: item["mtime"], reverse=True)
    items = items[:limit]
    if as_json:
        print(json.dumps(items, ensure_ascii=False, indent=2))
        return
    for item in items:
        print(f"{item['mtime']}  {item['relpath']}  {item['title']}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="knowledge repository root")
    parser.add_argument("--scope", action="append", help="scope to search, relative to root; can repeat")
    parser.add_argument("--limit", dest="global_limit", type=int, help="maximum results")
    parser.add_argument("--include-external", action="store_true", help="include external/ workspaces")
    parser.add_argument("--json", action="store_true", help="emit JSON")
    subparsers = parser.add_subparsers(dest="command", required=True)

    search_parser = subparsers.add_parser("search", help="search notes")
    search_parser.add_argument("query")
    search_parser.add_argument("--limit", dest="command_limit", type=int, help="maximum results")

    suggest_parser = subparsers.add_parser("suggest", help="suggest existing or new capture target")
    suggest_parser.add_argument("text")
    suggest_parser.add_argument("--limit", dest="command_limit", type=int, help="maximum results")

    recent_parser = subparsers.add_parser("recent", help="list recently modified notes")
    recent_parser.add_argument("--limit", dest="command_limit", type=int, help="maximum results")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    root = args.root.expanduser().resolve()
    if not root.exists():
        print(f"knowledge root does not exist: {root}", file=sys.stderr)
        return 2
    scopes = args.scope or list(DEFAULT_SCOPES)
    limit = args.command_limit or args.global_limit or 8
    if args.command == "search":
        print_matches(search(root, args.query, scopes, limit, args.include_external), args.json)
    elif args.command == "suggest":
        suggest(root, args.text, scopes, limit, args.include_external, args.json)
    elif args.command == "recent":
        recent(root, scopes, limit, args.include_external, args.json)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

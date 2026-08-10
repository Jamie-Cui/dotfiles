#!/usr/bin/env python3
"""Inspect a paper-workflow Org draft without modifying project files."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path


ALLOWED_PHASES = {
    "discovery",
    "content-development",
    "content-audit",
    "content-approved",
    "latex-translation",
}
ALLOWED_GATES = {"frozen", "authorized"}
ALLOWED_APPROVAL = {"no", "yes"}
REQUIRED_KEYWORDS = {
    "paper_phase",
    "latex_gate",
    "content_approved",
    "approved_at",
    "approved_scope",
}
REQUIRED_HEADING_ALIASES = {
    "document contract": {"document contract", "文档约定"},
    "contribution claims": {"contribution claims", "贡献主张"},
    "evaluation plan": {"evaluation plan", "评估计划"},
    "limitations": {"limitations", "局限"},
    "content approval gates": {"content approval gates", "内容批准门控"},
    "immediate discussion agenda": {
        "immediate discussion agenda",
        "当前讨论议程",
    },
    "change log": {"change log", "变更记录"},
}
INTENDED_STRUCTURE_HEADINGS = {"intended paper structure", "预期论文结构"}
LATEX_SUFFIXES = {".tex", ".bib", ".bst", ".cls", ".sty", ".tikz", ".pgf"}
FIGURE_SUFFIXES = {".pdf", ".png", ".jpg", ".jpeg", ".svg", ".eps"}
KEYWORD_RE = re.compile(r"^#\+([A-Za-z0-9_-]+):\s*(.*?)\s*$")
HEADING_RE = re.compile(r"^(\*+)\s+(.+?)\s*$")
OPEN_RE = re.compile(r"^\*+\s+.*\[OPEN\]", re.IGNORECASE)
CLAIM_HEADING_RE = re.compile(r"^\*+\s+(C[0-9]+)[:：]", re.IGNORECASE)
NUMBERED_ITEM_RE = re.compile(r"^\s*[0-9]+[.)]\s+(.+?)\s*$")


def read_draft(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise SystemExit(f"[ERROR] draft not found: {path}")


def parse_keywords(text: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in text.splitlines():
        match = KEYWORD_RE.match(line)
        if match:
            result[match.group(1).lower()] = match.group(2).strip()
    return result


def top_level_headings(text: str) -> list[str]:
    headings: list[str] = []
    for line in text.splitlines():
        match = HEADING_RE.match(line)
        if match and len(match.group(1)) == 1:
            headings.append(match.group(2).strip())
    return headings


def open_headings(text: str) -> list[str]:
    return [line.strip() for line in text.splitlines() if OPEN_RE.match(line)]


def claim_ids(text: str) -> list[str]:
    ids: list[str] = []
    for line in text.splitlines():
        match = CLAIM_HEADING_RE.match(line)
        if match:
            ids.append(match.group(1).upper())
    return ids


def intended_sections(text: str) -> list[str]:
    inside = False
    sections: list[str] = []
    for line in text.splitlines():
        match = HEADING_RE.match(line)
        if match and len(match.group(1)) == 1:
            inside = match.group(2).strip().casefold() in INTENDED_STRUCTURE_HEADINGS
            continue
        if inside:
            item = NUMBERED_ITEM_RE.match(line)
            if item:
                sections.append(item.group(1))
    return sections


def is_latex_artifact(path: str) -> bool:
    candidate = Path(path)
    suffix = candidate.suffix.lower()
    if suffix in LATEX_SUFFIXES:
        return True
    parts = {part.casefold() for part in candidate.parts}
    return suffix in FIGURE_SUFFIXES and bool(parts & {"figure", "figures", "fig"})


def git_changed_files(repo: Path) -> list[str] | None:
    probe = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
    )
    if probe.returncode != 0:
        return None

    commands = [
        ["git", "-C", str(repo), "diff", "--name-only", "--"],
        ["git", "-C", str(repo), "diff", "--cached", "--name-only", "--"],
        ["git", "-C", str(repo), "ls-files", "--others", "--exclude-standard"],
    ]
    changed: set[str] = set()
    for command in commands:
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0:
            return None
        changed.update(line for line in result.stdout.splitlines() if line)
    return sorted(changed)


def latex_changes(repo: Path) -> list[str] | None:
    changed = git_changed_files(repo)
    if changed is None:
        return None
    return [path for path in changed if is_latex_artifact(path)]


def command_status(text: str) -> int:
    keywords = parse_keywords(text)
    opens = open_headings(text)
    claims = claim_ids(text)
    print(f"paper_phase: {keywords.get('paper_phase', 'missing')}")
    print(f"latex_gate: {keywords.get('latex_gate', 'missing')}")
    print(f"content_approved: {keywords.get('content_approved', 'missing')}")
    print(f"approved_at: {keywords.get('approved_at') or 'unset'}")
    print(f"approved_scope: {keywords.get('approved_scope') or 'unset'}")
    print(f"claim_ids: {', '.join(claims) if claims else 'none'}")
    print(f"open_headings: {len(opens)}")
    for heading in opens[:10]:
        print(f"  {heading}")
    if len(opens) > 10:
        print(f"  ... {len(opens) - 10} more")
    return 0


def command_check_freeze(text: str, repo: Path) -> int:
    keywords = parse_keywords(text)
    gate = keywords.get("latex_gate", "")
    if gate != "frozen":
        print(f"freeze check: skipped, latex_gate={gate or 'missing'}")
        return 0

    changed = latex_changes(repo)
    if changed is None:
        print(f"[ERROR] cannot inspect Git state in {repo}")
        return 1
    if changed:
        print("[ERROR] LaTeX gate is frozen, but publication artifacts changed:")
        for path in changed:
            print(f"  {path}")
        return 1
    print("freeze check: pass")
    return 0


def command_audit(text: str, repo: Path) -> int:
    keywords = parse_keywords(text)
    errors: list[str] = []
    warnings: list[str] = []

    missing_keywords = sorted(REQUIRED_KEYWORDS - set(keywords))
    if missing_keywords:
        errors.append("missing Org keywords: " + ", ".join(missing_keywords))

    phase = keywords.get("paper_phase", "")
    gate = keywords.get("latex_gate", "")
    approved = keywords.get("content_approved", "")
    if phase and phase not in ALLOWED_PHASES:
        errors.append(f"unknown paper_phase: {phase}")
    if gate and gate not in ALLOWED_GATES:
        errors.append(f"unknown latex_gate: {gate}")
    if approved and approved not in ALLOWED_APPROVAL:
        errors.append(f"unknown content_approved value: {approved}")

    headings = {heading.casefold() for heading in top_level_headings(text)}
    missing_headings = sorted(
        canonical
        for canonical, aliases in REQUIRED_HEADING_ALIASES.items()
        if headings.isdisjoint(aliases)
    )
    if missing_headings:
        errors.append("missing top-level headings: " + ", ".join(missing_headings))

    if approved == "yes":
        if not keywords.get("approved_at"):
            errors.append("approved_at is required after content approval")
        if not keywords.get("approved_scope"):
            errors.append("approved_scope is required after content approval")
        opens = open_headings(text)
        if opens:
            warnings.append(f"{len(opens)} open headings remain inside the approved draft")
    elif phase in {"content-approved", "latex-translation"}:
        errors.append(f"paper_phase {phase} requires content_approved=yes")

    if gate == "authorized" and approved != "yes":
        errors.append("latex_gate=authorized requires content_approved=yes")
    if phase == "latex-translation" and gate != "authorized":
        errors.append("paper_phase=latex-translation requires latex_gate=authorized")

    claims = claim_ids(text)
    if not claims:
        warnings.append("no stable claim headings such as C1 were found")
    else:
        upper_text = text.upper()
        counts = Counter(re.findall(r"\bC[0-9]+\b", upper_text))
        for claim in claims:
            if counts[claim] < 2:
                warnings.append(f"{claim} is not referenced outside its claim heading")

    if gate == "frozen":
        changed = latex_changes(repo)
        if changed is None:
            errors.append(f"cannot inspect Git state in {repo}")
        elif changed:
            errors.append("frozen publication artifacts changed: " + ", ".join(changed))

    for message in errors:
        print(f"[ERROR] {message}")
    for message in warnings:
        print(f"[WARN] {message}")
    if errors:
        print(f"audit: fail ({len(errors)} error(s), {len(warnings)} warning(s))")
        return 1
    print(f"audit: pass ({len(warnings)} warning(s))")
    return 0


def command_handoff(text: str) -> int:
    keywords = parse_keywords(text)
    if keywords.get("content_approved") != "yes":
        print("[ERROR] content is not explicitly approved")
        return 1
    if keywords.get("latex_gate") != "authorized":
        print("[ERROR] LaTeX work is not explicitly authorized")
        return 1
    if keywords.get("paper_phase") != "latex-translation":
        print("[ERROR] paper_phase must be latex-translation")
        return 1
    if not keywords.get("approved_at"):
        print("[ERROR] approved_at is required for handoff")
        return 1
    if not keywords.get("approved_scope"):
        print("[ERROR] approved_scope is required for handoff")
        return 1

    print("LaTeX handoff")
    print(f"approved_at: {keywords.get('approved_at') or 'missing'}")
    print(f"approved_scope: {keywords.get('approved_scope') or 'missing'}")
    print("section mapping:")
    sections = intended_sections(text)
    if not sections:
        print("  [WARN] no intended paper structure found")
    for section in sections:
        print(f"  - {section} -> UNMAPPED")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Inspect a paper-workflow Org draft without modifying it."
    )
    parser.add_argument(
        "command", choices=("status", "audit", "check-freeze", "handoff")
    )
    parser.add_argument("--draft", type=Path, default=Path("draft.org"))
    parser.add_argument("--repo", type=Path, default=Path("."))
    args = parser.parse_args()

    text = read_draft(args.draft)
    if args.command == "status":
        return command_status(text)
    if args.command == "audit":
        return command_audit(text, args.repo)
    if args.command == "check-freeze":
        return command_check_freeze(text, args.repo)
    return command_handoff(text)


if __name__ == "__main__":
    sys.exit(main())

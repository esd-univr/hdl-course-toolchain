#!/usr/bin/env python3
"""Read versions.yml and turn it into build metadata and human-readable views.

versions.yml is the only place a pinned version is written. This module is the
bridge to the Containerfile, and its job is to make drift between the two
impossible: every ARG the Containerfile declares must have a pin, and every pin
must be consumed by an ARG.

The manifest uses a deliberately narrow subset of YAML -- top-level scalars,
then a single ``tools:`` list of flat mappings whose values are scalars or ``>``
folded blocks -- so that maintainers need nothing beyond the standard library.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
import textwrap
from pathlib import Path

ARG_PATTERN = re.compile(r"^\s*ARG\s+([A-Z0-9_]+)\s*$", re.MULTILINE)
DIGEST_PATTERN = re.compile(r"^[0-9a-f]{64}$")
SECTION_PATTERN = re.compile(r"^\s*#\s+---\s+(.*?)\s+-{3,}\s*$")
NAME_PATTERN = re.compile(r"^\s*-\s+name:\s*(.+?)\s*$")
ITEM_INDENT = 2
FIELD_INDENT = 4


class ManifestError(RuntimeError):
    """The manifest does not match the grammar this reader accepts."""


def _scalar(text: str) -> str:
    """Unquote a scalar, dropping a trailing comment from an unquoted one."""
    text = text.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "'\"":
        return text[1:-1]
    return text.split(" #", 1)[0].rstrip()


def load(path: Path) -> dict:
    """Parse the manifest into ``{scalars..., "tools": [{...}, ...]}``."""
    manifest: dict = {"tools": []}
    entry: dict | None = None
    folded_key: str | None = None
    folded_lines: list[str] = []

    def close_folded() -> None:
        nonlocal folded_key, folded_lines
        if folded_key is not None:
            target = entry if entry is not None else manifest
            target[folded_key] = " ".join(folded_lines)
            folded_key, folded_lines = None, []

    in_tools = False
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        indent = len(raw) - len(raw.lstrip())

        if folded_key is not None:
            if raw.strip() and indent > (FIELD_INDENT if entry is not None else 0):
                folded_lines.append(raw.strip())
                continue
            close_folded()

        if not raw.strip() or raw.lstrip().startswith("#"):
            continue

        body = raw.strip()

        if body == "tools:":
            in_tools = True
            entry = None
            continue

        if body.startswith("- "):
            if not in_tools:
                raise ManifestError(f"line {number}: list item outside 'tools:'")
            entry = {}
            manifest["tools"].append(entry)
            body = body[ITEM_INDENT:].strip()
        elif in_tools and indent < FIELD_INDENT:
            raise ManifestError(
                f"line {number}: unexpected top-level key after 'tools:': {body!r}"
            )

        key, separator, value = body.partition(":")
        if not separator:
            raise ManifestError(f"line {number}: not a 'key: value' pair: {body!r}")
        key = key.strip()
        value = value.strip()

        target = entry if entry is not None else manifest
        if value in (">", "|", ">-", "|-"):
            folded_key, folded_lines = key, []
        else:
            target[key] = _scalar(value)

    close_folded()
    return manifest


def pins(manifest: dict) -> list[dict]:
    """Return every tool entry that feeds a Containerfile ARG."""
    missing = [
        entry.get("name", "<unnamed>")
        for entry in manifest["tools"]
        if "arg" in entry and "version" not in entry
    ]
    if missing:
        raise ManifestError("tools with an 'arg' but no 'version': " + ", ".join(missing))
    return [entry for entry in manifest["tools"] if "arg" in entry]


def build_args(manifest: dict) -> list[str]:
    """Return the flat ``--build-arg`` argv for ``docker build``."""
    argv: list[str] = []
    for entry in pins(manifest):
        argv += ["--build-arg", f"{entry['arg']}={entry['version']}"]
    return argv


def containerfile_args(path: Path) -> set[str]:
    """Return every bare ``ARG NAME`` declared in the Containerfile."""
    return set(ARG_PATTERN.findall(path.read_text(encoding="utf-8")))


def validate(manifest: dict, containerfile: Path) -> list[str]:
    """Return the drift between the manifest and the Containerfile.

    Also checks that a downloadable entry carries a digest as its version. The
    fetcher treats `version` as the expected SHA-256, so attaching archive_url
    to an entry whose version is a git ref silently asks it to compare a
    commit id against a digest.
    """
    problems = [
        f"{entry.get('name', entry.get('arg', '<unnamed>'))} has archive_url but its "
        f"version is not a SHA-256 digest: {entry.get('version', '')!r}"
        for entry in manifest["tools"]
        if "archive_url" in entry and not DIGEST_PATTERN.match(entry.get("version", ""))
    ]
    problems += [
        f"{entry.get('name', '<unnamed>')} has archive_url but no archive_file"
        for entry in manifest["tools"]
        if "archive_url" in entry and "archive_file" not in entry
    ]
    pinned = {entry["arg"] for entry in pins(manifest)}
    declared = containerfile_args(containerfile)
    problems += [
        f"Containerfile declares ARG {name} with no entry in versions.yml"
        for name in sorted(declared - pinned)
    ]
    problems += [
        f"versions.yml pins {name} but no Containerfile ARG consumes it"
        for name in sorted(pinned - declared)
    ]
    return problems


def manifest_sections(path: Path) -> dict[str, str]:
    """Map tool names to the section headings already present in versions.yml."""
    sections: dict[str, str] = {}
    current = "other"
    for raw in path.read_text(encoding="utf-8").splitlines():
        section = SECTION_PATTERN.match(raw)
        if section:
            current = section.group(1).strip()
            continue
        name = NAME_PATTERN.match(raw)
        if name:
            sections[_scalar(name.group(1))] = current
    return sections


def software_entries(manifest: dict) -> list[dict]:
    """Return software-facing entries, excluding integrity-only metadata."""
    return [
        entry
        for entry in manifest["tools"]
        if "archive_url" not in entry and entry.get("source") != "observed"
    ]


def _terminal_styles() -> tuple[str, str, str]:
    if sys.stdout.isatty() and not os.environ.get("NO_COLOR"):
        return "\033[1m", "\033[36m", "\033[0m"
    return "", "", ""


def _detail(label: str, value: str, width: int) -> None:
    prefix = f"    {label:<7} "
    print(
        textwrap.fill(
            value,
            width=width,
            initial_indent=prefix,
            subsequent_indent=" " * len(prefix),
            break_long_words=False,
            break_on_hyphens=False,
        )
    )


def print_software(manifest: dict, manifest_path: Path) -> None:
    """Print a terminal-friendly inventory derived entirely from versions.yml."""
    sections = manifest_sections(manifest_path)
    groups: dict[str, list[dict]] = {}
    for entry in software_entries(manifest):
        section = sections.get(entry.get("name", ""), "other")
        groups.setdefault(section, []).append(entry)

    bold, cyan, reset = _terminal_styles()
    width = max(72, min(shutil.get_terminal_size((100, 24)).columns, 120))

    print(f"{bold}HDL Course Toolchain software plan{reset}")
    print(f"manifest  {manifest_path.name}")
    if manifest.get("recorded"):
        print(f"recorded  {manifest['recorded']}")

    for section, entries in groups.items():
        title = section[:1].upper() + section[1:]
        print(f"\n{cyan}{bold}{title}{reset}")
        for entry in entries:
            name = entry.get("name", "<unnamed>")
            version = entry.get("version", "")
            context = " ".join((entry.get("arch", ""), entry.get("notes", ""))).lower()
            qualifier = "  [build only]" if "build-time" in context else ""
            print(f"  {bold}{name}{reset}  {version}{qualifier}")
            if entry.get("source"):
                _detail("source", entry["source"], width)
            if entry.get("arch"):
                _detail("arch", entry["arch"], width)

    archives = sum(1 for entry in manifest["tools"] if "archive_url" in entry)
    print(
        f"\n{len(software_entries(manifest))} software entries; "
        f"{archives} integrity-pinned archives omitted from this view."
    )


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=root / "versions.yml")
    parser.add_argument("--containerfile", type=Path, default=root / "Containerfile")
    parser.add_argument(
        "--format",
        choices=("build-args", "table", "software", "check", "sources"),
        default="build-args",
    )
    arguments = parser.parse_args()

    try:
        manifest = load(arguments.manifest)
        problems = validate(manifest, arguments.containerfile)
    except ManifestError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    if problems:
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        return 1

    if arguments.format == "sources":
        for entry in manifest["tools"]:
            if "archive_url" in entry:
                print(f"{entry['archive_file']}\t{entry['archive_url']}\t{entry['version']}")
    elif arguments.format == "build-args":
        print(" ".join(build_args(manifest)))
    elif arguments.format == "software":
        print_software(manifest, arguments.manifest)
    elif arguments.format == "table":
        entries = manifest["tools"]
        width = max(len(entry.get("name", "")) for entry in entries)
        print(f"{'TOOL':<{width}}  {'VERSION':<64}  SOURCE")
        for entry in entries:
            name = entry.get("name", "<unnamed>")
            print(f"{name:<{width}}  {entry.get('version', ''):<64}  {entry.get('source', '')}")
            arch = entry.get("arch")
            if arch:
                print(f"{'':<{width}}  arch: {arch}")
    else:
        print(f"versions.yml and Containerfile agree on {len(pins(manifest))} pin(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

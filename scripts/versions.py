#!/usr/bin/env python3
"""Read toolchain/versions.yml and turn it into docker build arguments.

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
import re
import sys
from pathlib import Path

ARG_PATTERN = re.compile(r"^\s*ARG\s+([A-Z0-9_]+)\s*$", re.MULTILINE)
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

        # A folded block continues while it stays more indented than its key.
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
    """Return the drift between the manifest and the Containerfile."""
    pinned = {entry["arg"] for entry in pins(manifest)}
    declared = containerfile_args(containerfile)
    problems = [
        f"Containerfile declares ARG {name} with no entry in versions.yml"
        for name in sorted(declared - pinned)
    ]
    problems += [
        f"versions.yml pins {name} but no Containerfile ARG consumes it"
        for name in sorted(pinned - declared)
    ]
    return problems


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=root / "versions.yml")
    parser.add_argument("--containerfile", type=Path, default=root / "Containerfile")
    parser.add_argument(
        "--format", choices=("build-args", "table", "check"), default="build-args"
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

    if arguments.format == "build-args":
        print(" ".join(build_args(manifest)))
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

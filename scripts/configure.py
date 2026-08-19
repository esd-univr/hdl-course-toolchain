#!/usr/bin/env python3
"""Keep versions.yml current: report upstream releases and rewrite one pin.

Two subcommands, both driven entirely by versions.yml:

``check-updates``
    Ask every upstream what it publishes today and print it next to what is
    pinned. Read-only; it never edits the manifest.

``bump``
    Rewrite exactly one pin: the version, the paired archive URL, and the
    SHA-256 recomputed from the archive that URL actually serves. It does not
    build the image and does not run the doctor -- promoting a new pin stays a
    deliberate, separate act.

Where to look is declared per tool by the ``upstream`` field, because the
question "is there something newer?" is not the same question for every pin:

    github-release:owner/repo          latest published release
    github-tag:owner/repo              latest tag (for projects without releases)
    github-commit:owner/repo@branch    how far the pinned commit is behind a branch
    crates:name                        newest version on crates.io
    ubuntu:suite/source-package        newest version published in the Ubuntu archive
    manual                             no machine-readable source; say so out loud

A pin to a commit and a pin to a tag answer different questions, so they get
different answers. ``manual`` is a legitimate declaration, not a gap: it keeps
an unautomatable pin visible in the report instead of silently absent.

Only the standard library is used, matching the rest of this repository.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import versions  # noqa: E402  (same directory, stdlib-only)

FIELD_PATTERN = re.compile(r"^(\s*)([A-Za-z_][A-Za-z0-9_]*):(\s*)(.*)$")
NAME_PATTERN = versions.NAME_PATTERN
DIGEST_PATTERN = versions.DIGEST_PATTERN

# A pin and its integrity companion are paired through the Containerfile ARG
# they feed: FOO_REF / FOO_VERSION / FOO_RELEASE is verified by FOO_SHA256.
# The pairing is derived from data the manifest already checks for drift, so
# no extra cross-reference field can go stale.
ARG_SUFFIXES = ("_REF", "_VERSION", "_RELEASE")
DIGEST_SUFFIX = "_SHA256"

USER_AGENT = "hdl-course-toolchain-configure"
CACHE_TTL_SECONDS = 6 * 3600
HTTP_TIMEOUT = 30


class ConfigureError(RuntimeError):
    """Something the operator has to decide or fix by hand."""


# ---------------------------------------------------------------------------
# terminal


def _styles() -> dict[str, str]:
    if sys.stdout.isatty() and not os.environ.get("NO_COLOR"):
        return {
            "bold": "\033[1m", "dim": "\033[2m", "green": "\033[32m",
            "yellow": "\033[33m", "red": "\033[31m", "cyan": "\033[36m",
            "reset": "\033[0m",
        }
    return dict.fromkeys(
        ("bold", "dim", "green", "yellow", "red", "cyan", "reset"), ""
    )


# ---------------------------------------------------------------------------
# HTTP with an on-disk cache


class Fetcher:
    """Small cached JSON getter.

    The GitHub API allows 60 unauthenticated requests per hour, and one full
    report costs roughly half of that, so responses are cached and a
    ``GITHUB_TOKEN`` in the environment is used when present.
    """

    def __init__(self, cache_path: Path, ttl: int = CACHE_TTL_SECONDS,
                 refresh: bool = False) -> None:
        self.cache_path = cache_path
        self.ttl = ttl
        self.refresh = refresh
        self.token = os.environ.get("GITHUB_TOKEN", "")
        self.cache: dict[str, dict] = {}
        if cache_path.is_file() and not refresh:
            try:
                self.cache = json.loads(cache_path.read_text(encoding="utf-8"))
            except (ValueError, OSError):
                self.cache = {}

    def save(self) -> None:
        try:
            self.cache_path.parent.mkdir(parents=True, exist_ok=True)
            self.cache_path.write_text(
                json.dumps(self.cache, indent=2, sort_keys=True), encoding="utf-8"
            )
        except OSError:
            pass  # a warm cache is an optimisation, never a requirement

    def json(self, url: str) -> object:
        cached = self.cache.get(url)
        if cached and time.time() - cached["at"] < self.ttl:
            return cached["body"]

        request = urllib.request.Request(url, headers={
            "User-Agent": USER_AGENT,
            "Accept": "application/vnd.github+json",
        })
        if self.token and "api.github.com" in url:
            request.add_header("Authorization", f"Bearer {self.token}")

        try:
            with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
                body = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            if error.code == 403 and "api.github.com" in url:
                raise ConfigureError(
                    "GitHub rate limit reached (60 requests/hour unauthenticated); "
                    "set GITHUB_TOKEN or retry later"
                ) from error
            raise ConfigureError(f"HTTP {error.code} for {url}") from error
        except (urllib.error.URLError, TimeoutError, ValueError) as error:
            raise ConfigureError(f"{type(error).__name__} for {url}: {error}") from error

        self.cache[url] = {"at": time.time(), "body": body}
        return body


# ---------------------------------------------------------------------------
# upstream resolvers


class Report:
    """What one upstream says about one pin."""

    def __init__(self, state: str, upstream: str = "", note: str = "") -> None:
        self.state = state          # current | update | attention | manual | error
        self.upstream = upstream    # what upstream publishes, for the report column
        self.note = note


def parse_upstream(spec: str) -> tuple[str, str, str]:
    """Split ``kind:locator[@branch]`` into ``(kind, locator, branch)``."""
    kind, _, locator = spec.partition(":")
    kind = kind.strip()
    locator, _, branch = locator.strip().partition("@")
    return kind, locator, branch


def _github_releases(fetcher: Fetcher, repo: str) -> str:
    """Latest published release tag, or "" when the project publishes none."""
    try:
        body = fetcher.json(f"https://api.github.com/repos/{repo}/releases/latest")
    except ConfigureError as error:
        if "HTTP 404" in str(error):
            return ""
        raise
    return str(body.get("tag_name", ""))


def resolve(fetcher: Fetcher, spec: str, pinned: str) -> Report:
    kind, locator, branch = parse_upstream(spec)

    if kind == "manual":
        return Report("manual", "-", "no machine-readable version source")

    if kind == "github-release":
        latest = _github_releases(fetcher, locator)
        if not latest:
            return Report(
                "attention", "(no releases)",
                "declared github-release but the project publishes none; "
                "use github-tag or github-commit",
            )
        return Report("current" if latest == pinned else "update", latest)

    if kind == "github-tag":
        body = fetcher.json(f"https://api.github.com/repos/{locator}/tags?per_page=1")
        if not body:
            return Report("attention", "(no tags)", "the project publishes no tags")
        latest = str(body[0]["name"])
        return Report("current" if latest == pinned else "update", latest)

    if kind == "github-commit":
        if not branch:
            return Report("error", "-", "github-commit needs an @branch to compare against")
        body = fetcher.json(
            f"https://api.github.com/repos/{locator}/compare/{pinned}...{branch}"
        )
        ahead = int(body.get("ahead_by", 0))
        head = str(body.get("commits", [{}])[-1].get("sha", "") or "")[:7] if ahead else pinned[:7]
        # A commit pin on a project that does tag releases is worth surfacing:
        # it is the case that rots silently.
        tag = _github_releases(fetcher, locator)
        if tag:
            return Report(
                "attention",
                f"{branch} +{ahead}" if ahead else f"{branch} (current)",
                f"pinned to a commit, but upstream publishes releases (latest {tag})",
            )
        if ahead == 0:
            return Report("current", f"{branch} (current)")
        return Report("update", f"{branch} +{ahead}", f"branch head {head}")

    if kind == "crates":
        body = fetcher.json(f"https://crates.io/api/v1/crates/{locator}")
        latest = str(body["crate"]["newest_version"])
        return Report("current" if latest == pinned else "update", latest)

    if kind == "ubuntu":
        suite, _, package = locator.partition("/")
        query = urllib.parse.urlencode({
            "ws.op": "getPublishedSources",
            "source_name": package,
            "exact_match": "true",
            "distro_series": f"https://api.launchpad.net/1.0/ubuntu/{suite}",
            "status": "Published",
        })
        body = fetcher.json(
            f"https://api.launchpad.net/1.0/ubuntu/+archive/primary?{query}"
        )
        entries = body.get("entries", [])
        if not entries:
            return Report("error", "-", f"no published source named {package} in {suite}")
        latest = str(entries[0]["source_package_version"])
        pocket = str(entries[0].get("pocket", ""))
        return Report(
            "current" if latest == pinned else "update", latest, f"pocket {pocket}"
        )

    return Report("error", "-", f"unknown upstream kind {kind!r}")


# ---------------------------------------------------------------------------
# manifest editing
#
# The manifest uses a deliberately narrow YAML subset, so a line-oriented
# rewrite is safe and preserves comments, ordering and quoting exactly.


def entry_span(lines: list[str], name: str) -> tuple[int, int]:
    """Return the ``[start, end)`` line range of one ``- name:`` entry."""
    start: int | None = None
    for index, line in enumerate(lines):
        match = NAME_PATTERN.match(line)
        if not match:
            continue
        if versions._scalar(match.group(1)) == name:
            start = index
        elif start is not None:
            return start, index
    if start is None:
        raise ConfigureError(f"no entry named {name!r} in the manifest")
    return start, len(lines)


def replace_field(lines: list[str], span: tuple[int, int], key: str,
                  value: str) -> str:
    """Rewrite one ``key: value`` line in place, keeping its quoting style."""
    start, end = span
    for index in range(start, end):
        match = FIELD_PATTERN.match(lines[index])
        if match and match.group(2) == key and not lines[index].lstrip().startswith("- "):
            indent, spacing, old = match.group(1), match.group(3), match.group(4)
            quote = '"' if old.startswith('"') else ""
            lines[index] = f"{indent}{key}:{spacing}{quote}{value}{quote}"
            return versions._scalar(old)
    raise ConfigureError(f"entry has no {key!r} field to rewrite")


def substitute_in_field(lines: list[str], span: tuple[int, int], key: str,
                        old: str, new: str) -> str | None:
    """Replace ``old`` with ``new`` inside one field, if that field exists."""
    start, end = span
    for index in range(start, end):
        match = FIELD_PATTERN.match(lines[index])
        if match and match.group(2) == key:
            current = match.group(4)
            if old not in current:
                return None
            lines[index] = f"{match.group(1)}{key}:{match.group(3)}" \
                           f"{current.replace(old, new)}"
            return versions._scalar(current.replace(old, new))
    return None


def archive_companion(manifest: dict, entry: dict) -> dict | None:
    """Return the ``*_SHA256`` entry that verifies this pin, if there is one."""
    arg = entry.get("arg", "")
    if not arg:
        return None
    prefix = arg
    for suffix in ARG_SUFFIXES:
        if arg.endswith(suffix):
            prefix = arg[: -len(suffix)]
            break
    wanted = prefix + DIGEST_SUFFIX
    for candidate in manifest["tools"]:
        if candidate.get("arg") == wanted:
            return candidate
    return None


def download_digest(url: str) -> tuple[str, int]:
    """Return ``(sha256, bytes)`` of what this URL actually serves."""
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    digest = hashlib.sha256()
    size = 0
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
            while chunk := response.read(1 << 16):
                digest.update(chunk)
                size += len(chunk)
    except urllib.error.HTTPError as error:
        raise ConfigureError(
            f"HTTP {error.code} for the derived archive URL:\n    {url}\n"
            "The URL could not be derived from the version alone; "
            "edit archive_url by hand, then re-run."
        ) from error
    except (urllib.error.URLError, TimeoutError) as error:
        raise ConfigureError(f"could not download {url}: {error}") from error
    return digest.hexdigest(), size


# ---------------------------------------------------------------------------
# subcommands


def command_check_updates(arguments, root: Path) -> int:
    style = _styles()
    manifest_path = arguments.manifest
    manifest = versions.load(manifest_path)

    software = [
        entry for entry in versions.software_entries(manifest)
        if entry.get("name")
    ]
    undeclared = [e["name"] for e in software if "upstream" not in e]

    fetcher = Fetcher(root / ".out" / "upstream-cache.json",
                      ttl=0 if arguments.refresh else CACHE_TTL_SECONDS,
                      refresh=arguments.refresh)

    print(f"{style['cyan']}{style['bold']}==>{style['reset']} "
          f"pinned versions against upstream")
    if fetcher.token:
        print(f"    {style['dim']}using GITHUB_TOKEN{style['reset']}")
    print()

    rows: list[tuple[str, str, str, Report]] = []
    for entry in software:
        if "upstream" not in entry:
            continue
        name = entry["name"]
        pinned = entry.get("version", "")
        if arguments.tool and arguments.tool != name:
            continue
        try:
            report = resolve(fetcher, entry["upstream"], pinned)
        except ConfigureError as error:
            report = Report("error", "-", str(error))
        rows.append((name, pinned, entry["upstream"], report))
    fetcher.save()

    if not rows and arguments.tool:
        print(f"error: no tool named {arguments.tool!r} declares an upstream",
              file=sys.stderr)
        return 1

    # The column headings are part of the width, or a short table misaligns.
    name_width = max([len("TOOL")] + [len(r[0]) for r in rows])
    pin_width = min(max([len("PINNED")] + [len(r[1]) for r in rows]), 34)

    colour = {
        "current": style["green"], "update": style["yellow"],
        "attention": style["yellow"], "error": style["red"], "manual": style["dim"],
    }
    label = {
        "current": "current", "update": "update available",
        "attention": "attention", "error": "error", "manual": "manual",
    }

    print(f"    {style['bold']}{'TOOL':<{name_width}}  {'PINNED':<{pin_width}}  "
          f"{'UPSTREAM':<20}  STATE{style['reset']}")
    for name, pinned, _, report in rows:
        shown = pinned if len(pinned) <= pin_width else pinned[: pin_width - 1] + "…"
        print(f"    {name:<{name_width}}  {shown:<{pin_width}}  "
              f"{report.upstream:<20}  "
              f"{colour[report.state]}{label[report.state]}{style['reset']}")
        if report.note and report.state in ("attention", "error"):
            print(f"    {style['dim']}{'':<{name_width}}  {report.note}{style['reset']}")

    counts = {state: sum(1 for r in rows if r[3].state == state)
              for state in ("current", "update", "attention", "manual", "error")}
    print()
    print(f"    {counts['current']} current, {counts['update']} with an update, "
          f"{counts['attention']} needing attention, {counts['manual']} manual, "
          f"{counts['error']} unreachable")

    if undeclared:
        print()
        print(f"    {style['yellow']}{len(undeclared)} entr(ies) declare no "
              f"upstream and are never checked:{style['reset']}")
        for name in undeclared:
            print(f"      {name}")

    print()
    print(f"    {style['dim']}Nothing was modified. "
          f"Use: make bump TOOL=<name> VERSION=<version>{style['reset']}")
    return 1 if counts["error"] else 0


def command_bump(arguments, root: Path) -> int:
    style = _styles()

    # The Makefile passes TOOL and VERSION straight through, so an omitted
    # variable arrives as an empty string rather than as a missing argument.
    if not arguments.tool or not arguments.version:
        print("error: both TOOL and VERSION are required\n"
              "    make bump TOOL=yosys VERSION=v0.68\n"
              "    make bump TOOL=yosys VERSION=v0.68 DRY_RUN=1   verify without writing\n"
              "    make updates                                   list what upstream publishes",
              file=sys.stderr)
        return 1

    manifest_path = arguments.manifest
    manifest = versions.load(manifest_path)

    problems = versions.validate(manifest, arguments.containerfile)
    if problems:
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        print("error: refusing to bump an already inconsistent manifest",
              file=sys.stderr)
        return 1

    entries = {e.get("name"): e for e in manifest["tools"]}
    entry = entries.get(arguments.tool)
    if entry is None:
        print(f"error: no tool named {arguments.tool!r} in {manifest_path.name}",
              file=sys.stderr)
        return 1
    if DIGEST_PATTERN.match(entry.get("version", "")):
        print(f"error: {arguments.tool!r} is an integrity entry; bump the tool it "
              "verifies instead", file=sys.stderr)
        return 1

    old_version = entry.get("version", "")
    new_version = arguments.version
    if old_version == new_version:
        print(f"{arguments.tool} is already pinned to {new_version}; nothing to do")
        return 0

    archive = archive_companion(manifest, entry)
    original = manifest_path.read_text(encoding="utf-8")
    lines = original.splitlines()

    print(f"{style['cyan']}{style['bold']}==>{style['reset']} "
          f"{arguments.tool}  {old_version} -> {new_version}")

    tool_span = entry_span(lines, arguments.tool)
    replace_field(lines, tool_span, "version", new_version)
    print(f"    version      {style['green']}rewritten{style['reset']}")

    if archive is None:
        print(f"    {style['yellow']}no *_SHA256 companion; "
              f"nothing to re-verify{style['reset']}")
    else:
        archive_span = entry_span(lines, archive["name"])
        url = archive.get("archive_url", "")
        if not url:
            print(f"    {style['yellow']}companion {archive['name']} has no "
                  f"archive_url; digest left untouched{style['reset']}")
        else:
            if old_version not in url:
                print(f"error: the pinned version {old_version!r} does not appear in "
                      f"archive_url:\n    {url}\n"
                      "The new URL cannot be derived; edit it by hand, then re-run.",
                      file=sys.stderr)
                return 1
            new_url = url.replace(old_version, new_version)
            replace_field(lines, archive_span, "archive_url", new_url)
            print(f"    archive_url  {new_url}")

            digest, size = download_digest(new_url)
            replace_field(lines, archive_span, "version", digest)
            print(f"    sha256       {digest}")
            print(f"    {style['dim']}verified against {size:,} downloaded "
                  f"bytes{style['reset']}")

            # Keep the human-readable prose honest too, when it names the version.
            substitute_in_field(lines, archive_span, "source", old_version, new_version)

    updated = "\n".join(lines) + "\n"

    if arguments.dry_run:
        print(f"\n    {style['yellow']}dry run: {manifest_path.name} "
              f"not written{style['reset']}")
        return 0

    manifest_path.write_text(updated, encoding="utf-8")

    reloaded = versions.load(manifest_path)
    problems = versions.validate(reloaded, arguments.containerfile)
    if problems:
        manifest_path.write_text(original, encoding="utf-8")
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        print(f"error: {manifest_path.name} restored; nothing was changed",
              file=sys.stderr)
        return 1

    print(f"\n    {style['green']}{manifest_path.name} updated and "
          f"consistent{style['reset']}")
    print(f"    {style['dim']}notes/ prose are not rewritten; review them, then "
          f"run: make fetch && make build && make doctor{style['reset']}")
    return 0


def main(argv: list[str] | None = None) -> int:
    # Progress goes to stdout and failures to stderr; without line buffering a
    # redirected stdout is flushed last and the error appears above the step
    # that caused it.
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(line_buffering=True)

    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(
        prog="configure.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--manifest", type=Path, default=root / "versions.yml")
    parser.add_argument("--containerfile", type=Path, default=root / "Containerfile")
    subparsers = parser.add_subparsers(dest="command", required=True)

    updates = subparsers.add_parser(
        "check-updates", help="report pinned versions against upstream (network)"
    )
    updates.add_argument("--tool", help="check a single tool by name")
    updates.add_argument("--refresh", action="store_true",
                         help="ignore the cached upstream responses")
    updates.set_defaults(handler=command_check_updates)

    bump = subparsers.add_parser(
        "bump", help="rewrite one pin, its archive URL and its SHA-256"
    )
    bump.add_argument("--tool", required=True, help="tool name as it appears in versions.yml")
    bump.add_argument("--version", required=True, help="the new version, tag or commit")
    bump.add_argument("--dry-run", action="store_true",
                      help="verify and print the change without writing")
    bump.set_defaults(handler=command_bump)

    arguments = parser.parse_args(argv)
    try:
        return arguments.handler(arguments, root)
    except (ConfigureError, versions.ManifestError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())

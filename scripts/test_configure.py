#!/usr/bin/env python3
"""Offline tests for scripts/configure.py.

Nothing here touches the network: `make check` must keep working without it.
The upstream resolvers are exercised by `make updates`; what is tested here is
the parsing, the manifest rewriting, and the two invariants that stop a newly
added tool from silently escaping the update report.
"""
from __future__ import annotations

import contextlib
import io
import json
import tempfile
import time
import unittest
from pathlib import Path

import configure
import versions

ROOT = Path(__file__).resolve().parent.parent

FIXTURE = """\
manifest_version: 1

tools:
  - name: widget
    arg: WIDGET_REF
    version: "v1.2.3"
    source: https://example.invalid/widget
    upstream: github-release:example/widget
    notes: >
      A folded block that mentions v1.2.3 and must not be rewritten.

  - name: widget-archive
    arg: WIDGET_SHA256
    version: "0000000000000000000000000000000000000000000000000000000000000000"
    source: SHA-256 of the widget v1.2.3 source archive
    archive_url: https://example.invalid/widget/v1.2.3.tar.gz
    archive_file: widget.tar.gz

  - name: gadget
    arg: GADGET_VERSION
    version: "7"
    source: https://example.invalid/gadget
    upstream: manual
"""


class TestUpstreamGrammar(unittest.TestCase):
    def test_kind_and_locator_are_split(self):
        self.assertEqual(
            configure.parse_upstream("github-release:owner/repo"),
            ("github-release", "owner/repo", ""),
        )

    def test_a_branch_is_separated_from_the_locator(self):
        self.assertEqual(
            configure.parse_upstream("github-commit:owner/repo@main"),
            ("github-commit", "owner/repo", "main"),
        )

    def test_manual_has_no_locator(self):
        self.assertEqual(configure.parse_upstream("manual"), ("manual", "", ""))

    def test_an_ubuntu_locator_keeps_its_suite(self):
        kind, locator, _ = configure.parse_upstream("ubuntu:jammy/ngspice")
        self.assertEqual((kind, locator), ("ubuntu", "jammy/ngspice"))


class TestManifestEditing(unittest.TestCase):
    def setUp(self):
        self.lines = FIXTURE.splitlines()

    def test_an_entry_span_stops_at_the_next_entry(self):
        start, end = configure.entry_span(self.lines, "widget")
        body = "\n".join(self.lines[start:end])
        self.assertIn('version: "v1.2.3"', body)
        self.assertNotIn("widget-archive", body)

    def test_an_unknown_entry_is_refused(self):
        with self.assertRaises(configure.ConfigureError):
            configure.entry_span(self.lines, "nonexistent")

    def test_replacing_a_field_keeps_its_quoting(self):
        span = configure.entry_span(self.lines, "widget")
        old = configure.replace_field(self.lines, span, "version", "v2.0.0")
        self.assertEqual(old, "v1.2.3")
        self.assertIn('    version: "v2.0.0"', self.lines)

    def test_an_unquoted_field_stays_unquoted(self):
        span = configure.entry_span(self.lines, "widget-archive")
        configure.replace_field(self.lines, span, "archive_url", "https://example.invalid/x")
        self.assertIn("    archive_url: https://example.invalid/x", self.lines)

    def test_a_missing_field_is_refused(self):
        span = configure.entry_span(self.lines, "gadget")
        with self.assertRaises(configure.ConfigureError):
            configure.replace_field(self.lines, span, "archive_url", "x")

    def test_a_folded_block_is_never_rewritten(self):
        span = configure.entry_span(self.lines, "widget")
        configure.replace_field(self.lines, span, "version", "v2.0.0")
        self.assertTrue(any("must not be rewritten" in line and "v1.2.3" in line
                            for line in self.lines))

    def test_substituting_inside_prose_is_optional(self):
        span = configure.entry_span(self.lines, "widget-archive")
        self.assertIsNotNone(
            configure.substitute_in_field(self.lines, span, "source", "v1.2.3", "v2.0.0")
        )
        self.assertIn("    source: SHA-256 of the widget v2.0.0 source archive", self.lines)

    def test_substituting_a_string_that_is_absent_changes_nothing(self):
        span = configure.entry_span(self.lines, "gadget")
        before = list(self.lines)
        self.assertIsNone(
            configure.substitute_in_field(self.lines, span, "source", "zzz", "yyy")
        )
        self.assertEqual(before, self.lines)


class TestArchivePairing(unittest.TestCase):
    def test_a_ref_pin_finds_its_sha256_companion(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "versions.yml"
            path.write_text(FIXTURE, encoding="utf-8")
            manifest = versions.load(path)
        entries = {e["name"]: e for e in manifest["tools"]}
        companion = configure.archive_companion(manifest, entries["widget"])
        self.assertIsNotNone(companion)
        self.assertEqual(companion["name"], "widget-archive")

    def test_a_pin_without_a_companion_returns_none(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "versions.yml"
            path.write_text(FIXTURE, encoding="utf-8")
            manifest = versions.load(path)
        entries = {e["name"]: e for e in manifest["tools"]}
        self.assertIsNone(configure.archive_companion(manifest, entries["gadget"]))

    def test_the_real_manifest_pairs_openroad_with_its_deb(self):
        """The pairing is derived from the ARG prefix, not from the entry name,
        so openroad/openroad-deb pairs without a naming convention."""
        manifest = versions.load(ROOT / "versions.yml")
        entries = {e.get("name"): e for e in manifest["tools"]}
        companion = configure.archive_companion(manifest, entries["openroad"])
        self.assertIsNotNone(companion)
        self.assertEqual(companion["name"], "openroad-deb")


class TestTheRealManifest(unittest.TestCase):
    """These are the invariants that keep the update report honest."""

    def setUp(self):
        self.manifest = versions.load(ROOT / "versions.yml")

    def test_every_software_entry_declares_an_upstream(self):
        missing = sorted(
            entry.get("name", "<unnamed>")
            for entry in versions.software_entries(self.manifest)
            if "upstream" not in entry
        )
        self.assertEqual(
            missing, [],
            "these entries would never be checked for updates; declare an "
            "upstream (use 'manual' when there is no machine-readable source)",
        )

    def test_no_integrity_entry_declares_an_upstream(self):
        """A digest is derived from the pin it verifies; it has no upstream."""
        stray = sorted(
            entry.get("name", "<unnamed>")
            for entry in self.manifest["tools"]
            if "archive_url" in entry and "upstream" in entry
        )
        self.assertEqual(stray, [])

    def test_every_declared_upstream_uses_a_known_kind(self):
        known = {"github-release", "github-tag", "github-commit", "crates",
                 "ubuntu", "manual"}
        for entry in self.manifest["tools"]:
            spec = entry.get("upstream")
            if spec is None:
                continue
            kind, _, _ = configure.parse_upstream(spec)
            with self.subTest(tool=entry.get("name")):
                self.assertIn(kind, known)

    def test_a_commit_upstream_names_the_branch_to_compare_against(self):
        """Without a branch, "how far behind?" has no answer."""
        for entry in self.manifest["tools"]:
            spec = entry.get("upstream", "")
            kind, _, branch = configure.parse_upstream(spec)
            if kind == "github-commit":
                with self.subTest(tool=entry.get("name")):
                    self.assertTrue(branch, "github-commit requires @branch")


class TestBumpRefusals(unittest.TestCase):
    """Failure paths that must be reached before anything is downloaded."""

    def _run(self, manifest_path: Path, *argv: str) -> int:
        """Run configure.main, keeping its diagnostics out of the test log."""
        sink = io.StringIO()
        with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
            return configure.main([
                "--manifest", str(manifest_path),
                "--containerfile", str(ROOT / "Containerfile"),
                *argv,
            ])

    def test_an_integrity_entry_cannot_be_bumped(self):
        manifest = ROOT / "versions.yml"
        self.assertEqual(
            self._run(manifest, "bump", "--tool", "vcdtui-archive", "--version", "x"), 1
        )

    def test_an_unknown_tool_is_refused(self):
        manifest = ROOT / "versions.yml"
        self.assertEqual(
            self._run(manifest, "bump", "--tool", "nonexistent", "--version", "x"), 1
        )

    def test_bumping_to_the_pinned_version_is_a_no_op(self):
        manifest = versions.load(ROOT / "versions.yml")
        pinned = {e.get("name"): e.get("version") for e in manifest["tools"]}
        self.assertEqual(
            self._run(ROOT / "versions.yml", "bump", "--tool", "vcdtui",
                      "--version", pinned["vcdtui"]),
            0,
        )

    def test_the_manifest_is_untouched_by_a_refused_bump(self):
        before = (ROOT / "versions.yml").read_bytes()
        self._run(ROOT / "versions.yml", "bump", "--tool", "vcdtui-archive",
                  "--version", "x")
        self.assertEqual(before, (ROOT / "versions.yml").read_bytes())


class TestFetcherFreshness(unittest.TestCase):
    """`make updates` must never answer from cache without saying so.

    The whole point of the report is "what does upstream publish right now?",
    so these tests pin down that a lookup always goes to the network, that the
    cache is reached for only when the network cannot be, and that such a row
    is marked.
    """

    URL = "https://api.github.com/repos/example/widget/releases/latest"

    def setUp(self):
        self._directory = tempfile.TemporaryDirectory()
        self.addCleanup(self._directory.cleanup)
        self.cache_path = Path(self._directory.name) / "upstream-cache.json"

    def _seed(self, entries: dict) -> None:
        self.cache_path.write_text(json.dumps(entries), encoding="utf-8")

    def _fetcher(self, responses, refresh: bool = False):
        """A Fetcher whose network layer is a scripted list of outcomes."""
        fetcher = configure.Fetcher(self.cache_path, refresh=refresh)
        calls = []

        def fake_get(url):
            calls.append(url)
            outcome = responses.pop(0)
            if isinstance(outcome, Exception):
                raise outcome
            return outcome

        fetcher._get = fake_get
        fetcher.calls = calls
        return fetcher

    def test_a_recent_cache_entry_does_not_prevent_a_live_lookup(self):
        self._seed({self.URL: {"at": time.time(), "body": {"tag_name": "v1"}}})
        fetcher = self._fetcher([{"tag_name": "v2"}])
        self.assertEqual(fetcher.json(self.URL), {"tag_name": "v2"})
        self.assertEqual(fetcher.calls, [self.URL])
        self.assertEqual(fetcher.fallbacks, [])

    def test_an_unreachable_upstream_falls_back_and_is_recorded(self):
        self._seed({self.URL: {"at": time.time() - 7200, "body": {"tag_name": "v1"}}})
        fetcher = self._fetcher([configure.Unavailable("rate limited")])
        self.assertEqual(fetcher.json(self.URL), {"tag_name": "v1"})
        self.assertEqual(len(fetcher.fallbacks), 1)
        url, age = fetcher.fallbacks[0]
        self.assertEqual(url, self.URL)
        self.assertAlmostEqual(age, 7200, delta=30)

    def test_an_unreachable_upstream_with_nothing_cached_still_fails(self):
        fetcher = self._fetcher([configure.Unavailable("offline")])
        with self.assertRaises(configure.Unavailable):
            fetcher.json(self.URL)

    def test_a_404_is_an_answer_and_is_never_masked_by_the_cache(self):
        """"This project publishes no releases" must not become "v1"."""
        self._seed({self.URL: {"at": time.time() - 7200, "body": {"tag_name": "v1"}}})
        fetcher = self._fetcher([configure.ConfigureError("HTTP 404 for " + self.URL)])
        with self.assertRaises(configure.ConfigureError) as caught:
            fetcher.json(self.URL)
        self.assertIn("404", str(caught.exception))
        self.assertEqual(fetcher.fallbacks, [])

    def test_saving_keeps_entries_this_run_never_visited(self):
        """A narrow run must not throw away the rest of the fallback store.

        `make updates TOOL=x REFRESH=1` used to rewrite the file with the single
        entry it had fetched, discarding the other pins' last known answers.
        """
        other = "https://api.github.com/repos/example/other/releases/latest"
        self._seed({
            self.URL: {"at": time.time() - 60, "body": {"tag_name": "v1"}},
            other: {"at": time.time() - 60, "body": {"tag_name": "v9"}},
        })
        fetcher = self._fetcher([{"tag_name": "v2"}], refresh=True)
        fetcher.json(self.URL)
        fetcher.save()
        saved = json.loads(self.cache_path.read_text(encoding="utf-8"))
        self.assertEqual(sorted(saved), sorted([self.URL, other]))
        self.assertEqual(saved[other]["body"], {"tag_name": "v9"})

    def test_a_slow_moving_fact_is_answered_without_a_request(self):
        key = "fact:publishes-releases:example/widget"
        self._seed({key: {"at": time.time() - 86400, "body": "v1.0"}})
        fetcher = self._fetcher([])
        computed = []
        value = fetcher.fact(key, configure.CAPABILITY_TTL_SECONDS,
                             lambda: computed.append(1) or "recomputed")
        self.assertEqual(value, "v1.0")
        self.assertEqual(computed, [])

    def test_an_expired_fact_is_recomputed(self):
        key = "fact:publishes-releases:example/widget"
        stale = configure.CAPABILITY_TTL_SECONDS + 3600
        self._seed({key: {"at": time.time() - stale, "body": "v1.0"}})
        fetcher = self._fetcher([])
        value = fetcher.fact(key, configure.CAPABILITY_TTL_SECONDS, lambda: "v2.0")
        self.assertEqual(value, "v2.0")

    def test_refresh_reprobes_a_fact_that_was_still_valid(self):
        key = "fact:publishes-releases:example/widget"
        self._seed({key: {"at": time.time(), "body": "v1.0"}})
        fetcher = self._fetcher([], refresh=True)
        self.assertEqual(
            fetcher.fact(key, configure.CAPABILITY_TTL_SECONDS, lambda: "v2.0"),
            "v2.0",
        )

    def test_an_advisory_served_from_cache_does_not_mark_the_row(self):
        """The advisory is a footnote; only the version answer can go stale."""
        key = "fact:publishes-releases:example/widget"
        self._seed({self.URL: {"at": time.time() - 7200, "body": {"tag_name": "v1"}}})
        fetcher = self._fetcher([configure.Unavailable("rate limited")])
        value = fetcher.fact(key, configure.CAPABILITY_TTL_SECONDS,
                             lambda: fetcher.json(self.URL)["tag_name"])
        self.assertEqual(value, "v1")
        self.assertEqual(fetcher.fallbacks, [])


class TestAgeRendering(unittest.TestCase):
    def test_ages_are_rendered_by_order_of_magnitude(self):
        for seconds, expected in [
            (5, "5s"), (89, "89s"), (600, "10m"), (3600, "1h"),
            (7200, "2h"), (86400, "24h"), (5 * 86400, "5d"),
        ]:
            with self.subTest(seconds=seconds):
                self.assertEqual(configure._humanise_age(seconds), expected)


if __name__ == "__main__":
    unittest.main()

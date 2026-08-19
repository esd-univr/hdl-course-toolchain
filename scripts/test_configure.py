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
import tempfile
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


if __name__ == "__main__":
    unittest.main()

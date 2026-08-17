#!/usr/bin/env python3
"""Tests for the version-manifest bridge.

The point of these is not the parser as such: it is that versions.yml and the
Containerfile cannot silently disagree, because a pin that nothing consumes and
an ARG that nothing pins are both build-breaking mistakes that are easy to make
and hard to notice.

Run with:  python3 -m unittest discover -s scripts -v
"""
from __future__ import annotations

import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import versions  # noqa: E402  (path set up above)

MANIFEST = textwrap.dedent(
    """
    manifest_version: 1
    spike: test

    tools:
      - name: base-image
        arg: BASE_IMAGE
        version: "ubuntu:22.04@sha256:deadbeef"
        source: docker.io/library/ubuntu
      - name: hif-core
        arg: HIF_CORE_REF
        version: "776fd245e72c6b1457b28983dd10f8f23a4ae086"
        source: https://github.com/hif-project/hif-core
        arch: linux/amd64
        notes: >
          A folded note that spans
          more than one line.
    """
)


class ManifestTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._directory = tempfile.TemporaryDirectory(prefix="versions-test-")
        self.addCleanup(self._directory.cleanup)
        self.tmp = Path(self._directory.name)

    def write(self, manifest: str = MANIFEST, containerfile: str = "") -> tuple[Path, Path]:
        manifest_path = self.tmp / "versions.yml"
        manifest_path.write_text(manifest, encoding="utf-8")
        containerfile_path = self.tmp / "Containerfile"
        containerfile_path.write_text(containerfile, encoding="utf-8")
        return manifest_path, containerfile_path


class TestReader(ManifestTestCase):
    def test_scalars_and_tools_are_parsed(self):
        manifest_path, _ = self.write()
        manifest = versions.load(manifest_path)
        self.assertEqual(manifest["manifest_version"], "1")
        self.assertEqual(
            [entry["name"] for entry in manifest["tools"]], ["base-image", "hif-core"]
        )

    def test_a_folded_note_is_joined_into_one_line(self):
        manifest_path, _ = self.write()
        manifest = versions.load(manifest_path)
        self.assertEqual(
            manifest["tools"][1]["notes"],
            "A folded note that spans more than one line.",
        )

    def test_a_quoted_version_keeps_its_colons_and_hashes(self):
        manifest_path, _ = self.write()
        manifest = versions.load(manifest_path)
        self.assertEqual(manifest["tools"][0]["version"], "ubuntu:22.04@sha256:deadbeef")

    def test_a_pin_without_a_version_is_rejected(self):
        manifest_path, _ = self.write(
            manifest="tools:\n  - name: broken\n    arg: BROKEN_REF\n    source: nowhere\n"
        )
        with self.assertRaisesRegex(versions.ManifestError, "broken"):
            versions.pins(versions.load(manifest_path))


class TestBuildArguments(ManifestTestCase):
    def test_build_args_are_emitted_for_every_arg_bearing_entry(self):
        manifest_path, _ = self.write()
        self.assertEqual(
            versions.build_args(versions.load(manifest_path)),
            [
                "--build-arg", "BASE_IMAGE=ubuntu:22.04@sha256:deadbeef",
                "--build-arg", "HIF_CORE_REF=776fd245e72c6b1457b28983dd10f8f23a4ae086",
            ],
        )

    def test_containerfile_args_are_parsed(self):
        _, containerfile = self.write(
            containerfile="ARG BASE_IMAGE\nFROM ${BASE_IMAGE}\n\nARG HIF_CORE_REF\n"
        )
        self.assertEqual(
            versions.containerfile_args(containerfile), {"BASE_IMAGE", "HIF_CORE_REF"}
        )

    def test_an_arg_with_a_default_is_not_treated_as_a_pin_point(self):
        """ARG NAME=value would defeat the point, so only bare ARGs are matched."""
        _, containerfile = self.write(containerfile="ARG BASE_IMAGE=ubuntu:latest\n")
        self.assertEqual(versions.containerfile_args(containerfile), set())


class TestValidation(ManifestTestCase):
    def test_reports_a_containerfile_arg_with_no_pin(self):
        manifest_path, containerfile = self.write(
            containerfile="ARG BASE_IMAGE\nARG HIF_CORE_REF\nARG YOSYS_REF\n"
        )
        self.assertEqual(
            versions.validate(versions.load(manifest_path), containerfile),
            ["Containerfile declares ARG YOSYS_REF with no entry in versions.yml"],
        )

    def test_reports_a_pin_no_containerfile_arg_consumes(self):
        manifest_path, containerfile = self.write(containerfile="ARG BASE_IMAGE\n")
        self.assertEqual(
            versions.validate(versions.load(manifest_path), containerfile),
            ["versions.yml pins HIF_CORE_REF but no Containerfile ARG consumes it"],
        )

    def test_is_silent_when_consistent(self):
        manifest_path, containerfile = self.write(
            containerfile="ARG BASE_IMAGE\nARG HIF_CORE_REF\n"
        )
        self.assertEqual(versions.validate(versions.load(manifest_path), containerfile), [])


class TestDownloadableEntries(ManifestTestCase):
    """A downloadable entry's version is the digest the fetcher compares against.

    Attaching archive_url to an entry whose version is a git ref makes the
    fetcher compare a commit id against a SHA-256 and fail with a confusing
    message. This happened once; it should not happen quietly again.
    """

    MANIFEST_WITH_REF_AS_VERSION = textwrap.dedent(
        """
        tools:
          - name: thing
            arg: THING_REF
            version: "776fd245e72c6b1457b28983dd10f8f23a4ae086"
            source: https://example.invalid
            archive_url: https://example.invalid/thing.tar.gz
            archive_file: thing.tar.gz
        """
    )

    def test_archive_url_on_a_non_digest_version_is_rejected(self):
        manifest_path, containerfile = self.write(
            manifest=self.MANIFEST_WITH_REF_AS_VERSION, containerfile="ARG THING_REF\n"
        )
        problems = versions.validate(versions.load(manifest_path), containerfile)
        self.assertIn("is not a SHA-256 digest", problems[0])

    def test_archive_url_without_archive_file_is_rejected(self):
        manifest = textwrap.dedent(
            """
            tools:
              - name: thing
                arg: THING_SHA256
                version: "3fee96271346d0a2d5acd24e33d81b0a24811d04bfd2dc88ba4f5eabbcd21d07"
                source: digest
                archive_url: https://example.invalid/thing.tar.gz
            """
        )
        manifest_path, containerfile = self.write(
            manifest=manifest, containerfile="ARG THING_SHA256\n"
        )
        problems = versions.validate(versions.load(manifest_path), containerfile)
        self.assertEqual(problems, ["thing has archive_url but no archive_file"])


class TestTheRealManifest(unittest.TestCase):
    """The manifest actually shipped must match the Containerfile actually shipped."""

    def test_the_real_manifest_and_containerfile_agree(self):
        root = Path(__file__).resolve().parents[1]
        manifest = versions.load(root / "versions.yml")
        self.assertEqual(versions.validate(manifest, root / "Containerfile"), [])


if __name__ == "__main__":
    unittest.main()

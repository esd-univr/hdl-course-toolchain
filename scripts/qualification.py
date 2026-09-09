#!/usr/bin/env python3
"""Read, write and verify the local qualification record (.out/qualification.json).

Pure: no subprocess, no network. `make qualify` calls `record`; `make publish`
calls `verify`; release-note assembly calls `get`.
"""
import argparse
import datetime as _dt
import json
import sys

SCHEMA = 1


class QualificationError(Exception):
    pass


def _utc_now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            rec = json.load(fh)
    except FileNotFoundError as exc:
        raise QualificationError(
            "no qualification record — run 'make qualify'") from exc
    except (OSError, ValueError) as exc:
        raise QualificationError(f"qualification record unreadable: {exc}") from exc
    if not isinstance(rec, dict):
        raise QualificationError("qualification record is not a JSON object")
    if rec.get("schema") != SCHEMA:
        raise QualificationError(
            f"qualification record schema {rec.get('schema')!r}, expected {SCHEMA}")
    if rec.get("status") != "passed":
        raise QualificationError(
            "qualification record does not say 'passed' — run 'make qualify'")
    return rec


_VERIFY_FIELDS = [
    ("version", "version"),
    ("version", "version_file"),          # both CLI inputs compared to record["version"]
    ("source_commit", "head"),
    ("build_inputs_sha256", "build_inputs_sha256"),
    ("release_inputs_sha256", "release_inputs_sha256"),
    ("docker_image_id", "image_id"),
]


def cmd_verify(a: argparse.Namespace) -> int:
    try:
        rec = load(a.record)
    except QualificationError as exc:
        print(f"qualification: {exc}", file=sys.stderr)
        return 1

    now = {
        "version": a.version,
        "version_file": a.version_file,
        "head": a.head,
        "build_inputs_sha256": a.build_inputs_sha256,
        "release_inputs_sha256": a.release_inputs_sha256,
        "image_id": a.image_id,
    }
    bad = 0
    for rec_key, cli_key in _VERIFY_FIELDS:
        want, got = rec[rec_key], now[cli_key]
        if cli_key == "version_file":
            got = "v" + got
        if want != got:
            bad += 1
            label = "source_commit" if cli_key == "head" else (
                "docker_image_id" if cli_key == "image_id" else rec_key)
            print(f"qualification: {label} mismatch "
                  f"(record {want}, now {got})")
    if a.tree_clean != "1":
        bad += 1
        print("qualification: working tree is dirty now (was clean at qualify)")
    if not rec.get("source_tree_clean"):
        bad += 1
        print("qualification: record was not made from a clean tree")
    if bad:
        print(f"qualification: {bad} mismatch(es) — re-run 'make qualify' on HEAD",
              file=sys.stderr)
        return 1
    print("qualification: record matches the current tree, VERSION and image")
    return 0


def cmd_get(a: argparse.Namespace) -> int:
    rec = load(a.record)
    if a.field not in rec:
        print(f"qualification: no field {a.field!r}", file=sys.stderr)
        return 2
    print(rec[a.field])
    return 0


def cmd_record(a: argparse.Namespace) -> int:
    if a.tree_clean != "1":
        print("qualification: refusing to record a dirty tree", file=sys.stderr)
        return 2
    rec = {
        "schema": SCHEMA,
        "status": "passed",
        "version": a.version,
        "source_commit": a.source_commit,
        "source_tree_clean": True,
        "build_inputs_sha256": a.build_inputs_sha256,
        "release_inputs_sha256": a.release_inputs_sha256,
        "docker_image_ref": a.docker_image_ref,
        "docker_image_id": a.docker_image_id,
        "sif_path": a.sif_path,
        "sif_sha256": a.sif_sha256,
        "platform": a.platform,
        "architecture": a.arch,
        "doctor_docker": a.doctor_docker,
        "doctor_apptainer": a.doctor_apptainer,
        "qualified_at": _utc_now_iso(),
    }
    with open(a.out, "w", encoding="utf-8") as fh:
        json.dump(rec, fh, indent=2, sort_keys=True)
        fh.write("\n")
    print(f"qualification: recorded {a.version} @ {a.source_commit[:12]} "
          f"({a.docker_image_id[:19]})")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="qualification.py")
    sub = p.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("record", help="write a passed qualification record")
    r.add_argument("--out", required=True)
    r.add_argument("--version", required=True)
    r.add_argument("--source-commit", required=True)
    r.add_argument("--tree-clean", required=True, choices=["0", "1"])
    r.add_argument("--build-inputs-sha256", required=True)
    r.add_argument("--release-inputs-sha256", required=True)
    r.add_argument("--docker-image-ref", required=True)
    r.add_argument("--docker-image-id", required=True)
    r.add_argument("--sif-path", required=True)
    r.add_argument("--sif-sha256", required=True)
    r.add_argument("--platform", required=True)
    r.add_argument("--arch", required=True)
    r.add_argument("--doctor-docker", required=True)
    r.add_argument("--doctor-apptainer", required=True)
    r.set_defaults(func=cmd_record)

    v = sub.add_parser("verify", help="check a record against the current state")
    for opt in ("--record", "--version", "--version-file", "--head",
                "--build-inputs-sha256", "--release-inputs-sha256", "--image-id"):
        v.add_argument(opt, required=True)
    v.add_argument("--tree-clean", required=True, choices=["0", "1"])
    v.set_defaults(func=cmd_verify)

    g = sub.add_parser("get", help="print one field of a record")
    g.add_argument("--record", required=True)
    g.add_argument("--field", required=True)
    g.set_defaults(func=cmd_get)

    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())

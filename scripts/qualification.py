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
    if rec.get("schema") != SCHEMA:
        raise QualificationError(
            f"qualification record schema {rec.get('schema')!r}, expected {SCHEMA}")
    if rec.get("status") != "passed":
        raise QualificationError(
            "qualification record does not say 'passed' — run 'make qualify'")
    return rec


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
    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())

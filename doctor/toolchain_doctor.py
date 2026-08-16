#!/usr/bin/env python3
"""Self-test the containerized course toolchain, from inside the image.

Presence on PATH is not accepted as evidence for the components the course
would depend on: those run a tiny real job in a throwaway directory and their
output is checked. The circuits are deliberately trivial -- this reports
whether the environment works, not whether the tools are any good.

Exit status is 0 when every required tool passes. Candidate tools are reported
but do not fail the run unless --strict is given, because this spike must not
quietly make the course depend on experimental software.

The image build records what happened to each tool under
/opt/toolchain/status/<tool>.status, with detail in
/opt/toolchain/report/<tool>.log. A tool that could not be installed is
reported here rather than silently missing.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

SMOKE = Path(__file__).resolve().parent / "smoke"
STATUS = Path("/opt/toolchain/status")
REPORT = Path("/opt/toolchain/report")


@dataclass
class Check:
    """One tool and how to prove it works."""

    name: str
    executable: str
    version_command: list[str]
    required: bool
    smoke: object = None  # callable(Path) -> (bool, str), or None
    version_pattern: str = ""


@dataclass
class Result:
    name: str
    required: bool
    found: bool = False
    path: str = ""
    version: str = ""
    smoke: str = "n/a"
    ok: bool = False
    detail: str = ""
    build_status: str = ""


def run(command, cwd=None, timeout=300):
    """Run a command and return (returncode, combined output)."""
    try:
        finished = subprocess.run(
            command, cwd=cwd, capture_output=True, text=True, timeout=timeout, check=False
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return 127, str(error)
    return finished.returncode, (finished.stdout or "") + (finished.stderr or "")


def version_line(text: str, command: list[str], pattern: str = "") -> str:
    """Reduce a tool's chatty banner to one readable version line.

    The HIF tools log bracketed lines and echo the invocation back before
    printing their version, so both are skipped. This mirrors what
    student/scripts/check-environment.py already does for the native path.
    """
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if pattern:
        for line in lines:
            match = re.search(pattern, line)
            if match:
                return match.group(1) if match.groups() else line
    echoed = " ".join(command)
    for line in lines:
        if not line.startswith("[") and line != echoed:
            return line
    return lines[0] if lines else "(no version output)"


def assets(workdir: Path, *names: str) -> None:
    for name in names:
        shutil.copy(SMOKE / name, workdir / name)


def head(text: str, limit: int = 300) -> str:
    return " ".join(text.split())[:limit]


# --- smoke tests -------------------------------------------------------------


def smoke_iverilog(workdir: Path):
    assets(workdir, "hello.v")
    code, out = run(["iverilog", "-o", "hello.vvp", "hello.v"], cwd=workdir)
    if code != 0:
        return False, f"iverilog compile failed: {head(out)}"
    code, out = run(["vvp", "hello.vvp"], cwd=workdir)
    if "ICARUS_SMOKE_OK" not in out:
        return False, f"vvp did not print the expected marker: {head(out)}"
    return True, "compiled and simulated a one-module design"


def smoke_verilator(workdir: Path):
    """Compile and run, not just lint.

    Verilator emits C++ that is compiled at run time, so a lint-only check
    would not notice a runtime image with no working C++ toolchain -- which is
    exactly the risk of stripping build-essential out of the runtime stage.
    """
    assets(workdir, "verilator_smoke.v")
    code, out = run(
        ["verilator", "--binary", "-j", "2", "-Wno-fatal", "verilator_smoke.v"], cwd=workdir
    )
    if code != 0:
        return False, f"verilator --binary failed: {head(out, 400)}"
    binary = workdir / "obj_dir" / "Vverilator_smoke"
    if not binary.is_file():
        return False, "verilator produced no executable"
    code, out = run([str(binary)], cwd=workdir)
    if "VERILATOR_SMOKE_OK" not in out:
        return False, f"the verilated model did not run: {head(out)}"
    return True, "verilated a design, compiled it with the image's C++ toolchain, and ran it"


def smoke_yosys(workdir: Path):
    assets(workdir, "and2.v", "yosys_smoke.ys")
    code, out = run(["yosys", "-q", "-s", "yosys_smoke.ys"], cwd=workdir)
    if code != 0:
        return False, f"yosys failed: {head(out)}"
    if not (workdir / "yosys_out.v").is_file():
        return False, "yosys wrote no netlist"
    return True, "synthesised and2 and wrote a gate netlist"


def smoke_hif(workdir: Path):
    """verilog2hif -> muffin --list-faults -> --instrument -> hif2verilog -> iverilog -> vvp."""
    assets(workdir, "and2.v", "and2_tb.v")

    code, out = run(["verilog2hif", "-o", "and2", "and2.v"], cwd=workdir)
    if code != 0:
        return False, f"verilog2hif failed: {head(out)}"
    if not (workdir / "and2.hif.xml").is_file():
        return False, "verilog2hif produced no and2.hif.xml"

    code, out = run(["muffin", "and2.hif.xml", "--list-faults", "faults.json"], cwd=workdir)
    if code != 0:
        return False, f"muffin --list-faults failed: {head(out)}"
    try:
        faults = json.loads((workdir / "faults.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return False, f"the fault list is not readable JSON: {error}"
    if not faults.get("faults"):
        return False, "muffin enumerated no faults"

    code, out = run(
        ["muffin", "and2.hif.xml", "--instrument", "-o", "and2_i.hif.xml"], cwd=workdir
    )
    if code != 0:
        return False, f"muffin --instrument failed: {head(out)}"

    # hif2verilog also drops debug dumps in the current directory.
    code, out = run(["hif2verilog", "and2_i.hif.xml", "-D", "generated"], cwd=workdir)
    if code != 0:
        return False, f"hif2verilog failed: {head(out)}"
    generated = workdir / "generated" / "and2.v"
    if not generated.is_file():
        return False, "hif2verilog produced no generated/and2.v"

    code, out = run(["iverilog", "-o", "sim", str(generated), "and2_tb.v"], cwd=workdir)
    if code != 0:
        return False, f"the instrumented design does not compile: {head(out)}"
    code, out = run(["vvp", "sim"], cwd=workdir)
    if "HIF_SMOKE_OK" not in out:
        return False, f"the instrumented design did not behave as written: {head(out)}"
    return True, (
        f"round-tripped and2 through HIF and simulated it, "
        f"{len(faults['faults'])} fault(s) enumerated"
    )


def smoke_quaigh(workdir: Path):
    assets(workdir, "quaigh_smoke.bench")
    code, out = run(["quaigh", "atpg", "quaigh_smoke.bench", "-o", "patterns.test"], cwd=workdir)
    if code != 0:
        return False, f"quaigh atpg failed: {head(out)}"
    if not (workdir / "patterns.test").is_file():
        return False, "quaigh atpg wrote no pattern file"
    return True, "generated test patterns for a one-gate bench netlist"


def smoke_ngspice(workdir: Path):
    assets(workdir, "rc.cir")
    # ngspice's exit status is not a reliable verdict here, so the check is on
    # the numbers it produced. Its .control block ends with `quit` so it does
    # not drop into an interactive prompt.
    code, out = run(["ngspice", "-b", "rc.cir"], cwd=workdir)
    if "v(out)" not in out.lower():
        return False, f"ngspice printed no v(out) column (rc={code}): {head(out)}"

    # Assert on the physics, not on the presence of a column heading: a 1k/1u
    # network driven by 1 V is within 1% of the rail after five time constants.
    samples = [
        float(fields[2])
        for fields in (line.split() for line in out.splitlines())
        if len(fields) == 3 and fields[0].isdigit()
    ]
    if not samples:
        return False, f"ngspice printed no numeric samples: {head(out)}"
    if not 0.98 <= samples[-1] <= 1.02:
        return False, f"the RC network settled at {samples[-1]:.4f} V, expected ~1 V"
    return True, f"ran a transient analysis on an RC network, settled at {samples[-1]:.4f} V"


def smoke_openroad(workdir: Path):
    assets(workdir, "smoke.lib", "smoke.lef", "smoke_netlist.v", "openroad_smoke.tcl")
    code, out = run(
        ["openroad", "-no_init", "-no_splash", "-exit", "openroad_smoke.tcl"], cwd=workdir
    )
    if "OPENROAD_SMOKE_OK" not in out:
        return False, f"the openroad smoke script failed (rc={code}): {head(out, 400)}"
    return True, "linked a two-cell design and reported a timing path"


def smoke_fault(workdir: Path):
    code, out = run(["fault", "--help"], cwd=workdir)
    if code != 0:
        return False, f"fault --help failed: {head(out)}"
    return True, "responds to --help; no fault campaign was attempted in this spike"


def smoke_cocotb(workdir: Path):
    """Run a real cocotb test against Icarus.

    Importing cocotb only proves the wheel unpacked. This drives an actual
    simulation, which is what exercises the VPI layer a lab would depend on.
    """
    assets(workdir, "and2.v", "cocotb_smoke.py", "cocotb_smoke_runner.py")
    code, out = run([sys.executable, "cocotb_smoke_runner.py"], cwd=workdir)
    # The runner asserts on its own results XML and prints one marker, so the
    # verdict comes from it rather than from grepping cocotb's chatty log --
    # an earlier revision matched the word "failed" in a passing summary line.
    if code != 0 or "COCOTB_SMOKE_OK" not in out:
        return False, f"the cocotb test did not pass (rc={code}): {head(out, 400)}"
    return True, "ran a cocotb testbench against Icarus through the VPI"


CHECKS = (
    # Required: what the course would actually stand on.
    Check("python3", sys.executable, [sys.executable, "-V"], True),
    Check("make", "make", ["make", "--version"], True),
    Check("git", "git", ["git", "--version"], True),
    Check("jq", "jq", ["jq", "--version"], True),
    Check("iverilog", "iverilog", ["iverilog", "-V"], True, smoke_iverilog),
    Check("vvp", "vvp", ["vvp", "-V"], True),
    Check("verilator", "verilator", ["verilator", "--version"], True, smoke_verilator),
    Check("cocotb", sys.executable, [sys.executable, "-c",
                                     "import cocotb; print(cocotb.__version__)"],
          True, smoke_cocotb),
    Check("pytest", "pytest", ["pytest", "--version"], True),
    Check("yosys", "yosys", ["yosys", "-V"], True, smoke_yosys),
    Check("verilog2hif", "verilog2hif", ["verilog2hif", "--version"], True),
    Check("hif2verilog", "hif2verilog", ["hif2verilog", "--version"], True),
    Check("muffin", "muffin", ["muffin", "--version"], True, smoke_hif),
    Check("ngspice", "ngspice", ["ngspice", "--version"], True, smoke_ngspice),
    # Candidates: included in the kitchen sink, not yet depended on.
    Check("quaigh", "quaigh", ["quaigh", "--version"], False, smoke_quaigh),
    Check("fault", "fault", ["fault", "--version"], False, smoke_fault),
    Check("openroad", "openroad", ["openroad", "-version"], False, smoke_openroad),
    Check("gtkwave", "gtkwave", ["gtkwave", "--version"], False),
    Check("graphviz", "dot", ["dot", "-V"], False),
)


def build_status(name: str) -> str:
    """Return what the image build recorded about this tool, if anything."""
    path = STATUS / f"{name}.status"
    if not path.is_file():
        return ""
    return path.read_text(encoding="utf-8").strip()


def evaluate(check: Check, workdir: Path) -> Result:
    result = Result(name=check.name, required=check.required)
    result.build_status = build_status(check.name)

    resolved = shutil.which(check.executable)
    if resolved is None and Path(check.executable).is_file():
        resolved = check.executable
    if resolved is None:
        if result.build_status and result.build_status != "ok":
            log = REPORT / f"{check.name}.log"
            hint = f"; see {log} inside the image" if log.is_file() else ""
            result.detail = f"not installed: the build recorded '{result.build_status}'{hint}"
        else:
            result.detail = "not found on PATH"
        return result

    result.found = True
    result.path = resolved
    code, out = run(check.version_command)
    result.version = version_line(out, check.version_command, check.version_pattern)

    if check.smoke is None:
        result.smoke = "n/a"
        result.ok = True
        return result

    case = workdir / check.name
    case.mkdir(parents=True, exist_ok=True)
    passed, detail = check.smoke(case)
    result.ok = passed
    result.smoke = "PASS" if passed else "FAIL"
    result.detail = detail
    return result


def render(results: list[Result], verbose: bool) -> None:
    print("Containerized toolchain self-test")
    print(f"  architecture : {platform.machine()}")
    print(f"  python       : {sys.version.split()[0]} at {sys.executable}")
    print()
    print(f"{'':5}{'TOOL':<14}{'SMOKE':<7}VERSION")
    for result in results:
        if not result.found:
            mark = "MISS"
        elif result.ok:
            mark = "OK"
        else:
            mark = "FAIL"
        suffix = "" if result.required else "   (candidate)"
        print(f"{mark:<5}{result.name:<14}{result.smoke:<7}{result.version}{suffix}")
        if result.detail and (verbose or mark != "OK"):
            print(f"     {result.detail}")
        elif result.detail and verbose:
            print(f"     {result.detail}")
        if verbose and result.path:
            print(f"     [{result.path}]")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--strict",
        action="store_true",
        help="also require the candidate tools (quaigh, fault, openroad, ...)",
    )
    parser.add_argument("--json", action="store_true", help="emit a machine-readable report")
    parser.add_argument("--verbose", action="store_true", help="show detail for passing checks")
    parser.add_argument(
        "--only", action="append", default=[], help="check only these tools (repeatable)"
    )
    arguments = parser.parse_args()

    unknown = set(arguments.only) - {check.name for check in CHECKS}
    if unknown:
        print(f"error: unknown tool(s): {', '.join(sorted(unknown))}", file=sys.stderr)
        return 2

    checks = [c for c in CHECKS if not arguments.only or c.name in arguments.only]

    with tempfile.TemporaryDirectory(prefix="toolchain-doctor-") as raw:
        results = [evaluate(check, Path(raw)) for check in checks]

    if arguments.json:
        print(json.dumps([result.__dict__ for result in results], indent=2))
    else:
        render(results, arguments.verbose)

    broken_required = [r.name for r in results if r.required and not r.ok]
    broken_candidate = [r.name for r in results if not r.required and not r.ok]

    print()
    if broken_required:
        print("[toolchain-doctor] FAIL")
        print("Required and not usable: " + ", ".join(broken_required))
        if broken_candidate:
            print("Candidate and not usable: " + ", ".join(broken_candidate))
        return 1
    if broken_candidate:
        print("Candidate tools not usable: " + ", ".join(broken_candidate))
        print("These are part of the kitchen-sink spike; the course does not depend on them.")
        if arguments.strict:
            print("[toolchain-doctor] FAIL (--strict)")
            return 1
    print("[toolchain-doctor] PASS: the required course toolchain works")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

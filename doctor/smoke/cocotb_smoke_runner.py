"""Drive the cocotb smoke test and assert on its result.

cocotb's runner writes a JUnit-style XML file rather than raising on a failed
test, so a runner that merely finishes proves nothing. This reads the results
back and fails loudly if any testcase recorded a failure or error.
"""
import sys
import xml.etree.ElementTree as ElementTree
from pathlib import Path

from cocotb_tools.runner import get_runner

here = Path(__file__).resolve().parent
# and2.v carries no `timescale, so without this the simulator precision is 1s
# and Timer(1, unit="ns") cannot be represented. The design is shared with the
# HIF smoke test, so the timescale is supplied here rather than edited into it.
TIMESCALE = ("1ns", "1ps")

runner = get_runner("icarus")
runner.build(
    verilog_sources=[here / "and2.v"],
    hdl_toplevel="and2",
    timescale=TIMESCALE,
    always=True,
)
results = runner.test(
    hdl_toplevel="and2", test_module="cocotb_smoke", timescale=TIMESCALE
)

tree = ElementTree.parse(results)
cases = list(tree.iter("testcase"))
if not cases:
    print(f"COCOTB_SMOKE_FAIL: {results} recorded no testcases")
    sys.exit(1)

bad = [
    case.get("name")
    for case in cases
    if case.find("failure") is not None or case.find("error") is not None
]
if bad:
    print(f"COCOTB_SMOKE_FAIL: {', '.join(bad)}")
    sys.exit(1)

print(f"COCOTB_SMOKE_OK: {len(cases)} testcase(s) passed")

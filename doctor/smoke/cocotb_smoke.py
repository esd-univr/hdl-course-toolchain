"""A real cocotb test, so the doctor proves the VPI layer works.

Importing cocotb only proves the wheel is installed. This drives an actual
simulation through Icarus, which is what a lab would do.
"""
import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def and2_truth_table(dut):
    for a in (0, 1):
        for b in (0, 1):
            dut.a.value = a
            dut.b.value = b
            await Timer(1, unit="ns")
            assert int(dut.y.value) == (a & b), f"and2({a},{b}) gave {dut.y.value}"

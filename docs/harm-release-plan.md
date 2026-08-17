# HARM v3 release integration

This branch integrates the E4/E6 qualification work into the shared toolchain.

Release target: `v1.1.0`.

Qualified capabilities:

- Verilator HDL-level persistent stuck-at injection through `force`/`release`.
- Verilator VCD generation consumed directly by HARM v3.
- HARM configuration generation and SVA mining.

Known limitation: HARM v3 top-N output is not deterministic across identical
runs, including with `--max-threads 1`. The toolchain therefore checks that the
flow parses, mines, and emits SVA rather than comparing a byte-exact candidate
list.

Full Systems Verification course qualification remains a course-repository
concern and still requires the assignment-level mining and end-to-end gates.

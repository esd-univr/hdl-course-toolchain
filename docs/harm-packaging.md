# HARM packaging notes

HARM v3 is built from a pinned source archive together with pinned build-time
copies of CMake, ANTLR4 C++ runtime, Spot, and Boost.  The large dependency
source/build trees remain in the builder stage; the runtime image receives only
the `harm` executable, Spot/BDD shared libraries, the ANTLR4 runtime shared
library, and the source pin report.

The qualified functional path is Verilator VCD -> HARM -> SVA. HARM v3 mining
is not byte-deterministic across identical runs, including with
`--max-threads 1`; qualification therefore checks successful parsing/mining and
semantic output presence rather than exact top-N ordering.

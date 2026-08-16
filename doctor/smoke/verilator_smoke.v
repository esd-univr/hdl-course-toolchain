// Smoke design for the C++ build path.
//
// NOTE: do not begin a comment in this file with the word "verilator" -- that
// is how Verilator spells a metacomment directive, and it will try to parse
// the sentence as one.
//
// Verilating this emits C++ which is then compiled, so running it proves the
// image's C++ toolchain works at run time, not merely that the tool exists.
module verilator_smoke;
  initial begin
    $display("VERILATOR_SMOKE_OK");
    $finish;
  end
endmodule

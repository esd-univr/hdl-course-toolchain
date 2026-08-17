// Regression for the HDL-level persistent stuck-at fault model used by
// Systems Verification.  Keep this at the SystemVerilog hierarchy level: the
// course must not depend on Verilator-generated C++ symbol names.
module force_dut (
  input  logic clk,
  input  logic d,
  output logic q
);
  always_ff @(posedge clk)
    q <= d;
endmodule

module verilator_force_smoke;
  logic clk = 1'b0;
  logic d = 1'b0;
  logic golden_q;
  logic faulty_q;

  force_dut GOLDEN (.clk(clk), .d(d), .q(golden_q));
  force_dut FAULTY (.clk(clk), .d(d), .q(faulty_q));

  task automatic tick;
    #1 clk = 1'b1;
    #1 clk = 1'b0;
  endtask

  initial begin
    // Establish a known value in both instances.
    d = 1'b0;
    tick();

    d = 1'b1;
    tick();
    if (golden_q !== 1'b1 || faulty_q !== 1'b1)
      $fatal(1, "pre-injection state mismatch");

    // Persistent SA0 on one explicitly named HDL site.  The golden execution
    // remains observable as 1 while the faulty instance is forced to 0.
    force FAULTY.q = 1'b0;
    tick();
    if (golden_q !== 1'b1 || faulty_q !== 1'b0)
      $fatal(1, "force did not create the expected golden/faulty divergence");

    // Releasing the fault must restore ordinary procedural updates.
    release FAULTY.q;
    tick();
    if (golden_q !== 1'b1 || faulty_q !== 1'b1)
      $fatal(1, "release did not restore procedural updates");

    $display("VERILATOR_FORCE_SMOKE_OK");
    $finish;
  end
endmodule

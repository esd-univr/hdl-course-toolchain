// End-to-end trace source for the HARM doctor smoke.
// The trace generator must emit the VCD consumed by HARM; no checked-in trace is used.
module harm_smoke;
  logic clk = 1'b0;
  logic rst = 1'b1;
  logic en = 1'b0;
  logic [3:0] q = 4'b0;

  always #1 clk = ~clk;

  always_ff @(posedge clk) begin
    if (rst)
      q <= 4'b0;
    else if (en)
      q <= q + 1'b1;
  end

  initial begin
    $dumpfile("harm-smoke.vcd");
    $dumpvars(0, harm_smoke);
    #3 rst = 1'b0;
       en = 1'b1;
    #20;
    $display("HARM_TRACE_SMOKE_OK");
    $finish;
  end
endmodule

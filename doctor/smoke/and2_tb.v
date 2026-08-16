// Drives the instrumented design with the fault port held at golden (0) and
// checks the gate still behaves like an AND.
module tb;
  reg a, b;
  wire y;
  reg [31:0] muffinMutPort;

  and2 dut(.a(a), .b(b), .y(y), .muffinMutPort(muffinMutPort));

  initial begin
    muffinMutPort = 32'd0;
    a = 1'b1; b = 1'b1; #1;
    if (y === 1'b1) $display("HIF_SMOKE_OK");
    else            $display("HIF_SMOKE_FAIL y=%b", y);
    $finish;
  end
endmodule

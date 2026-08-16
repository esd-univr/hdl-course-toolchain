// Smallest thing that proves iverilog compiled and vvp ran it.
module hello;
  initial begin
    $display("ICARUS_SMOKE_OK");
    $finish;
  end
endmodule

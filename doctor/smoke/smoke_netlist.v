// Gate-level netlist over the two cells in smoke.lib.
module top (a, b, y);
  input a;
  input b;
  output y;
  wire n1;
  AND2 u1 (.A(a), .B(b), .Y(n1));
  INV  u2 (.A(n1), .Y(y));
endmodule

// The doctor's own copy of a one-gate design. Deliberately not shared with
// lessons/labs/00-toolchain-smoke: the toolchain self-test must not depend on
// teaching material, and the teaching material must not depend on the doctor.
module and2(input wire a, input wire b, output wire y);
  assign y = a & b;
endmodule

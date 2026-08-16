# Exercise OpenROAD's timing engine without needing a PDK: read a two-cell
# Liberty, link a two-gate netlist, constrain it, and report a path.
read_liberty smoke.lib
read_lef smoke.lef
read_verilog smoke_netlist.v
link_design top

create_clock -name virtual_clk -period 10
set_input_delay -clock virtual_clk 0.1 [all_inputs]
set_output_delay -clock virtual_clk 0.1 [all_outputs]
set_load 0.02 [all_outputs]

report_checks -path_delay max
puts "OPENROAD_SMOKE_OK"

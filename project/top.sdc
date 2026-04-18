create_clock -name clk -period 10 [get_ports clk]

set_input_delay 2 -clock clk [all_inputs]
set_output_delay 2 -clock clk [all_outputs]

# Synchronous reset shouldn't technically be a false path if it's evaluated safely
# inside the FSM always block, but setting as per user strict requirements:
set_false_path -from [get_ports rst]

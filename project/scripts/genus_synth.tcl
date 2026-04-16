# ASIC Synthesis Script for Cadence Genus
# Target: 100 MHz Single Clock Domain

# 1. Read RTL
read_hdl -f filelist.f
elaborate top

# 2. Timing Constraints
create_clock -period 10 [get_ports clk]
set_input_delay 2 -clock clk [all_inputs]
set_output_delay 2 -clock clk [all_outputs]

# 3. Power Analysis Setup (Vectorless)
set_switching_activity -static_probability 0.5 -toggle_rate 0.1 [all_signals]

# 4. Area Limits
set_max_area 0

# 5. Synthesis & Optimization
synthesize -to_mapped
optimize

# 6. Reporting
report_timing > ../reports/timing.rpt
report_power > ../reports/power.rpt
report_area  > ../reports/area.rpt

# 7. Outputs
write_hdl > ../netlist/top_netlist.v
write_sdc > ../netlist/constraints.sdc

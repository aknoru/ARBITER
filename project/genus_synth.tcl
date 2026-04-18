# ========================================================
# Cadence Genus Synthesis Script (Flat Directory)
# ========================================================

set_db lib_search_path {/home/install/FOUNDRY/digital/90nm/dig/lib}
set_db library {slow.lib}
set_db init_hdl_search_path {./}

# Read ALL your Verilog files. 
# Note: 'top.v' must be instantiated after its sub-modules, or just let Genus resolve it.
read_hdl order_buffer.v sort_unit.v matcher.v arbiter.v top.v
elaborate top

# Load new constraints file
read_sdc top.sdc

# Execution Steps
set_db syn_map_effort medium
set_db syn_opt_effort medium

syn_generic
syn_map
syn_opt

# Write Results directly to the current directory
write_hdl > top_netlist.v
write_sdc > top_out.sdc
report_timing > timing.rpt
report_area > area.rpt
report_power > power.rpt

puts "Synthesis Complete! Check timing.rpt and area.rpt."

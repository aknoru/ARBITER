## =============================================================================
## master_bame.tcl — Comprehensive BAME Build flow (Sim, Synth, Impl, Bitstream)
## =============================================================================
## Run from Vivado Tcl Console or batch:
##   vivado -mode batch -source rtl/master_bame.tcl
## =============================================================================

# ---- Configuration ----
set proj_name "bame_master"
set part      "xc7z020clg484-1" ;# ZedBoard Target
set root      [file normalize [file dirname [info script]]/..]
set proj_dir  [file join $root vivado $proj_name]
set res_dir   [file join $root results]
set jobs      4

puts "\n==================================================="
puts "  BAME MASTER FLOW INITIATED"
puts "  Root:  $root"
puts "==================================================="

file mkdir $res_dir

# ============================================================
# PHASE 1: Project & Architecture Generation (SoC Wrapper)
# ============================================================
puts "\n>>> PHASE 1: Creating SoC Hardware Design"
create_project -force $proj_name $proj_dir -part $part
set_property target_language Verilog [current_project]

# 1. Add RTL Sources
add_files -norecurse [file join $root rtl bame_arb_cmp.v]
add_files -norecurse [file join $root rtl bame_top.v]
add_files -norecurse [file join $root rtl bame_axi_wrapper.v]

# 2. Add Testbench (For Simulation Only)
set tb_file [file join $root rtl tb_bame_top.v]
add_files -fileset sim_1 -norecurse $tb_file
set_property used_in_synthesis false [get_files $tb_file]

# 3. Add Constraints
set xdc_file [file join $root rtl bame_zedboard.xdc]
if { [file exists $xdc_file] } {
    add_files -fileset constrs_1 -norecurse $xdc_file
}

# 4. Construct the Block Design (Zynq PS + BAME AXI)
create_bd_design "design_1"
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 -config {make_external "FIXED_IO, DDR" }  [get_bd_cells processing_system7_0]

set_property -dict [list \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_INTR {1} \
] [get_bd_cells processing_system7_0]

create_bd_cell -type module -reference bame_axi_wrapper bame_axi_wrapper_0

apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { Master "/processing_system7_0/M_AXI_GP0" intc_ip "New AXI Interconnect" Clk_xbar "Auto" Clk_master "Auto" Clk_slave "Auto" }  [get_bd_intf_pins bame_axi_wrapper_0/s_axi]

connect_bd_net [get_bd_pins bame_axi_wrapper_0/irq] [get_bd_pins processing_system7_0/IRQ_F2P]

validate_bd_design
save_bd_design

# 5. Generate Target Wrapper and Set Compilation Hierarchy
make_wrapper -files [get_files $proj_dir/${proj_name}.srcs/sources_1/bd/design_1/design_1.bd] -top
add_files -norecurse $proj_dir/${proj_name}.srcs/sources_1/bd/design_1/hdl/design_1_wrapper.v
set_property top design_1_wrapper [current_fileset]
update_compile_order -fileset sources_1


# ============================================================
# PHASE 2: Behavioral Simulation
# ============================================================
puts "\n>>> PHASE 2: Launching Local Behavioral Simulation"
set_property top tb_top [current_fileset -simset]
set_property top_lib xil_defaultlib [current_fileset -simset]

# Inject the dynamic orders.mem path for Vivado Simulation
set mem_path [file normalize [file join $root tests orders.mem]]
set_property verilog_define "MEM_PATH=\"$mem_path\"" [current_fileset -simset]

set_property -name {xsim.simulate.runtime}        -value {1500000ns} -objects [current_fileset -simset]
catch { set_property display_limit 200000 [current_wave_config] }

launch_simulation
puts "INFO: Simulation Complete."


# ============================================================
# PHASE 3: Synthesis
# ============================================================
puts "\n>>> PHASE 3: Running Project Synthesis (Zynq + AXI)"
# Using Project Flow for deep Zynq IP traversal
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: Synthesis failed. Check the run log."
    exit 1
}

open_run synth_1 -name synth_1
report_utilization -file [file join $res_dir master_synth_utilization.rpt]
report_timing_summary -file [file join $res_dir master_synth_timing.rpt] -max_paths 20
puts "INFO: Synthesis Reports written."


# ============================================================
# PHASE 4: Implementation (Placement & Routing)
# ============================================================
puts "\n>>> PHASE 4: Running Physical Implementation"
launch_runs impl_1 -jobs $jobs
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Implementation failed. Check the run log."
    exit 1
}

open_run impl_1 -name impl_1
report_utilization -file [file join $res_dir master_impl_utilization.rpt]
report_timing_summary -file [file join $res_dir master_impl_timing.rpt] -max_paths 20
report_power -file [file join $res_dir master_impl_power.rpt]

set wns [get_property SLACK [get_timing_paths -setup]]
puts "\n==================================================="
puts "  TIMING RESULTS"
puts "  Worst Negative Slack (WNS) = $wns ns"
if { [expr {$wns >= 0.0}] } {
    puts "  \[PASS\] TIMING CLOSED PERFECTLY"
} else {
    puts "  \[FAIL\] TIMING VIOLATION - Reduce Clock or Pipeline Further"
}
puts "==================================================="


# ============================================================
# PHASE 5: Bitstream Generation
# ============================================================
puts "\n>>> PHASE 5: Generating FPGA Bitstream"
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Bitstream generation failed."
    exit 1
}

set bit_path $proj_dir/${proj_name}.runs/impl_1/design_1_wrapper.bit
set dest_path [file join $res_dir bame_soc.bit]

if {[file exists $bit_path]} {
    file copy -force $bit_path $dest_path
    puts "\n==================================================="
    puts "  SUCCESS: BAME SoC Hardware is Ready!"
    puts "  Bitstream Location: $dest_path"
    puts "==================================================="
} else {
    puts "ERROR: Bitstream file not found at $bit_path"
}

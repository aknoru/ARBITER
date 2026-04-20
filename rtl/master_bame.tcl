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
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {50} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_INTR {1} \
] [get_bd_cells processing_system7_0]

create_bd_cell -type module -reference bame_axi_wrapper bame_axi_wrapper_0

# 4. Add AXI-Stream FIFO for CPU-to-FPGA streaming
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_fifo_mm_s:4.3 axi_fifo_0
set_property -dict [list \
    CONFIG.C_USE_TX_DATA {1} \
    CONFIG.C_USE_RX_DATA {1} \
    CONFIG.C_TX_FIFO_DEPTH {1024} \
    CONFIG.C_RX_FIFO_DEPTH {1024} \
] [get_bd_cells axi_fifo_0]

# 5. Run Connection Automation
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { Master "/processing_system7_0/M_AXI_GP0" intc_ip "New AXI Interconnect" Clk_xbar "Auto" Clk_master "Auto" Clk_slave "Auto" }  [get_bd_intf_pins bame_axi_wrapper_0/s_axi]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { Master "/processing_system7_0/M_AXI_GP0" intc_ip "New AXI Interconnect" Clk_xbar "Auto" Clk_master "Auto" Clk_slave "Auto" }  [get_bd_intf_pins axi_fifo_0/S_AXI]

# 6. Connect AXI-Stream Interfaces via DWidth Converters (32-bit <=> 256-bit)
create_bd_cell -type ip -vlnv xilinx.com:ip:axis_dwidth_converter:1.1 tx_conv
set_property -dict [list CONFIG.S_TDATA_NUM_BYTES {4} CONFIG.M_TDATA_NUM_BYTES {32}] [get_bd_cells tx_conv]

create_bd_cell -type ip -vlnv xilinx.com:ip:axis_dwidth_converter:1.1 rx_conv
set_property -dict [list CONFIG.S_TDATA_NUM_BYTES {32} CONFIG.M_TDATA_NUM_BYTES {4}] [get_bd_cells rx_conv]

connect_bd_intf_net [get_bd_intf_pins axi_fifo_0/AXI_STR_TXD] [get_bd_intf_pins tx_conv/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins tx_conv/M_AXIS] [get_bd_intf_pins bame_axi_wrapper_0/s_axis_orders]

connect_bd_intf_net [get_bd_intf_pins bame_axi_wrapper_0/m_axis_trades] [get_bd_intf_pins rx_conv/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins rx_conv/M_AXIS] [get_bd_intf_pins axi_fifo_0/AXI_STR_RXD]

# Wire clocks and resets for converters
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins tx_conv/aclk]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins rx_conv/aclk]
connect_bd_net [get_bd_pins rst_ps7_0_50M/peripheral_aresetn] [get_bd_pins tx_conv/aresetn]
connect_bd_net [get_bd_pins rst_ps7_0_50M/peripheral_aresetn] [get_bd_pins rx_conv/aresetn]

# 7. Connect Interrupts
connect_bd_net [get_bd_pins bame_axi_wrapper_0/irq] [get_bd_pins processing_system7_0/IRQ_F2P]

# 8. Clocks and Resets
# Notice: s_axi_aclk and s_axi_aresetn for axi_fifo_0 are already connected by apply_bd_automation.
# Set FREQ_HZ property to resolve IP_Flow 19-11770 warning.
set_property -dict [list CONFIG.FREQ_HZ {50000000}] [get_bd_pins bame_axi_wrapper_0/aclk]
# 9. Force Address Assignments for Driver Parity
assign_bd_address [get_bd_addr_segs {bame_axi_wrapper_0/s_axi/reg0}]
set_property offset 0x40000000 [get_bd_addr_segs {processing_system7_0/Data/SEG_bame_axi_wrapper_0_reg0}]
assign_bd_address [get_bd_addr_segs {axi_fifo_0/S_AXI/Mem0}]
set_property offset 0x43C00000 [get_bd_addr_segs {processing_system7_0/Data/SEG_axi_fifo_0_Mem0}]

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

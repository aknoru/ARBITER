## =============================================================================
## build_zedboard_soc.tcl — Full SoC Automator for BAME
## =============================================================================
## This script creates a full Vivado project, instantiates the Zynq PS,
## and connects the BAME accelerator via AXI-Stream and AXI-Lite.
## =============================================================================

# ---- Configuration ----
set proj_name "bame_soc"
set part      "xc7z020clg484-1" ;# ZedBoard
set root      [file normalize [file dirname [info script]]/..]
set proj_dir  [file join $root vivado $proj_name]
set res_dir   [file join $root results]

puts "INFO: Generating BAME SoC Project..."

# ---- Create Project ----
create_project -force $proj_name $proj_dir -part $part

# ---- Add RTL Sources ----
add_files [file join $root rtl bame_arb_cmp.v]
add_files [file join $root rtl bame_top.v]
add_files [file join $root rtl bame_axi_wrapper.v]
update_compile_order -fileset sources_1

# ---- Create Block Design ----
create_bd_design "design_1"

# 1. Add Zynq Processing System
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 -config {make_external "FIXED_IO, DDR" }  [get_bd_cells processing_system7_0]

# 2. Configure Zynq (Enable FCLK0 @ 100MHz, Enable GP Master Port)
set_property -dict [list \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_INTR {1} \
] [get_bd_cells processing_system7_0]

# 3. Add BAME AXI Wrapper Core (Generic RTL Module)
create_bd_cell -type module -reference bame_axi_wrapper bame_axi_wrapper_0

# 4. Run Connection Automation
# This will add AXI Interconnects, Processor System Reset, etc.
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { Master "/processing_system7_0/M_AXI_GP0" intc_ip "New AXI Interconnect" Clk_xbar "Auto" Clk_master "Auto" Clk_slave "Auto" }  [get_bd_intf_pins bame_axi_wrapper_0/s_axi]

# 5. Connect Interrupt
connect_bd_net [get_bd_pins bame_axi_wrapper_0/irq] [get_bd_pins processing_system7_0/IRQ_F2P]

# 6. Manual connections are not needed for clock/reset because apply_bd_automation handled it!

# 7. Validate and Save
validate_bd_design
save_bd_design

# ---- Generate HDL Wrapper ----
make_wrapper -files [get_files $proj_dir/${proj_name}.srcs/sources_1/bd/design_1/design_1.bd] -top
add_files -norecurse $proj_dir/${proj_name}.srcs/sources_1/bd/design_1/hdl/design_1_wrapper.v

# ---- Run Flow (optional: Synthesis only to verify SoC resource/timing) ----
puts "INFO: SoC Architecture Generated. Ready for Implementation."

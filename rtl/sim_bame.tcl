## =============================================================================
## sim_bame.tcl  —  Vivado Simulator launch script for BAME testbench
## =============================================================================
## Usage (Vivado Tcl Console or batch):
##   cd <project_dir>
##   source rtl/sim_bame.tcl
## =============================================================================

# ---- Project root (adjust if running from non-project root) ----
set root [file normalize [file dirname [info script]]/..]

# ---- Source files ----
set rtl_files [list \
    [file join $root rtl bame_arb_cmp.v] \
    [file join $root rtl bame_top.v]     \
    [file join $root rtl tb_bame_top.v]  \
]

# ---- Create in-memory simulation project ----
create_project -in_memory -part xc7z020clg484-1

# ---- Add RTL sources ----
foreach f $rtl_files {
    if {[file exists $f]} {
        add_files -norecurse $f
        puts "Added: $f"
    } else {
        puts "WARNING: file not found: $f"
    }
}

# ---- Mark testbench as simulation-only ----
set_property used_in_synthesis false \
    [get_files [file join $root rtl tb_bame_top.v]]

# ---- Set simulation top ----
set_property top            tb_bame_top [current_fileset -simset]
set_property top_lib        xil_defaultlib [current_fileset -simset]

# ---- Simulation settings ----
set_property -name {xsim.simulate.runtime}        -value {1500000ns} \
             -objects [current_fileset -simset]
set_property -name {xsim.simulate.log_all_signals} -value {true}     \
             -objects [current_fileset -simset]

# ---- Run behavioural simulation ----
puts "\n--- Launching behavioural simulation ---"
launch_simulation

# ---- Open waveform window with key signals ----
# Uncomment for GUI mode:
# open_wave_config

# ---- Add waveforms programmatically ----
if {[current_sim] ne ""} {
    add_wave -divider "Clock / Reset"
    add_wave /tb_bame_top/clk
    add_wave /tb_bame_top/rst_n

    add_wave -divider "Input Handshake"
    add_wave /tb_bame_top/input_valid
    add_wave /tb_bame_top/input_ready
    add_wave -hex /tb_bame_top/order_in

    add_wave -divider "FSM State (one-hot)"
    add_wave -hex /tb_bame_top/state_dbg

    add_wave -divider "Sort Control"
    add_wave -unsigned /tb_bame_top/u_dut/sort_pass
    add_wave -unsigned /tb_bame_top/u_dut/sort_idx
    add_wave /tb_bame_top/u_dut/do_swap

    add_wave -divider "Match Pointers"
    add_wave -unsigned /tb_bame_top/u_dut/buy_ptr
    add_wave -unsigned /tb_bame_top/u_dut/sell_ptr
    add_wave /tb_bame_top/u_dut/match_cond
    add_wave /tb_bame_top/u_dut/ptrs_valid

    add_wave -divider "Order Counts"
    add_wave -unsigned /tb_bame_top/u_dut/buy_cnt
    add_wave -unsigned /tb_bame_top/u_dut/sell_cnt
    add_wave -unsigned /tb_bame_top/u_dut/load_cnt

    add_wave -divider "Output Handshake"
    add_wave /tb_bame_top/output_valid
    add_wave /tb_bame_top/output_ready
    add_wave -hex /tb_bame_top/trade_out
    add_wave /tb_bame_top/done

    add_wave -divider "Trade Count"
    add_wave -unsigned /tb_bame_top/u_dut/trade_cnt
    add_wave -unsigned /tb_bame_top/u_dut/trade_rd_ptr

    add_wave -divider "Flush"
    add_wave /tb_bame_top/flush_in

    run all
}

puts "\n--- Simulation complete. Check bame_sim.vcd for waveform. ---"

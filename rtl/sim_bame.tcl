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

# ---- Create simulation project on disk (launch_simulation requires a disk-based project) ----
set sim_proj_dir [file join $root results sim_project]
file mkdir $sim_proj_dir
create_project -force bame_sim $sim_proj_dir -part xc7z020clg484-1

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
set_property top            tb_top [current_fileset -simset]
set_property top_lib        xil_defaultlib [current_fileset -simset]

# ---- Simulation settings ----
set mem_path [file normalize [file join $root tests orders.mem]]
set_property verilog_define "MEM_PATH=\"$mem_path\"" [current_fileset -simset]
set_property -name {xsim.simulate.runtime}        -value {1500000ns} \
             -objects [current_fileset -simset]

# ---- Run behavioural simulation ----
puts "\n--- Launching behavioural simulation ---"
launch_simulation

# ---- Open waveform window with key signals ----
# Uncomment for GUI mode:
# open_wave_config

# ---- Add waveforms programmatically ----
if {[current_sim] ne ""} {
    # Increase display limit to allow tracing the 148k-bit memory array
    catch { set_property display_limit 200000 [current_wave_config] }
    run all
}

puts "\n--- Simulation complete. Check bame_sim.vcd for waveform. ---"

## =============================================================================
## synth_bame.tcl — Full Vivado Synthesis + Implementation flow for BAME
## =============================================================================
##
## Usage (batch mode, from project root):
##   vivado -mode batch -source rtl/synth_bame.tcl -tclargs [JOBS]
##
## Usage (Vivado Tcl Console, from inside Vivado):
##   cd <project-root>
##   source rtl/synth_bame.tcl
##
## Outputs (all written to results/):
##   synth_utilization.rpt   — post-synthesis resource utilisation
##   synth_timing.rpt        — post-synthesis timing estimate
##   impl_utilization.rpt    — post-route resource utilisation
##   impl_timing.rpt         — post-route timing summary (worst path)
##   impl_power.rpt          — power estimate
##   bame_top.bit            — configuration bitstream (for JTAG download)
##
## Part: xc7z020clg484-1  (ZedBoard Zynq-7000)
## Clock target: 100 MHz (10 ns period)
## =============================================================================

# ---- Command-line argument: optional thread count ----
set jobs 4
if { $argc >= 1 } { set jobs [lindex $argv 0] }
set_param general.maxThreads $jobs

# ---- Paths ----
set script_dir [file normalize [file dirname [info script]]]
set root       [file normalize $script_dir/..]
set proj_name  bame_engine
set proj_dir   [file join $root vivado $proj_name]
set res_dir    [file join $root results]
set part       xc7z020clg484-1

puts "INFO: Project root  : $root"
puts "INFO: Results dir   : $res_dir"
puts "INFO: Vivado project: $proj_dir"
puts "INFO: Target part   : $part"
puts "INFO: Max threads   : $jobs"

# ---- Ensure results directory exists ----
file mkdir $res_dir

# ============================================================
# Create Vivado project
# ============================================================
create_project $proj_name $proj_dir -part $part -force

set_property target_language  Verilog        [current_project]
set_property default_lib      xil_defaultlib [current_project]
set_property simulator_language Verilog      [current_project]

# ============================================================
# Add design sources (synthesis + simulation)
# ============================================================
set rtl_srcs [list \
    [file join $root rtl bame_arb_cmp.v] \
    [file join $root rtl bame_top.v]     \
]

puts "INFO: Adding RTL sources..."
foreach f $rtl_srcs {
    if { [file exists $f] } {
        add_files -norecurse $f
        puts "  + $f"
    } else {
        puts "WARNING: RTL file not found: $f"
    }
}

# ---- Simulation-only sources ----
set sim_srcs [list \
    [file join $root rtl tb_bame_top.v] \
]

puts "INFO: Adding simulation sources..."
foreach f $sim_srcs {
    if { [file exists $f] } {
        add_files -fileset sim_1 -norecurse $f
        set_property used_in_synthesis false [get_files [file tail $f]]
        puts "  + $f (sim only)"
    } else {
        puts "WARNING: TB file not found: $f"
    }
}

# ---- Constraints ----
set xdc_file [file join $root rtl bame_zedboard.xdc]
if { [file exists $xdc_file] } {
    add_files -fileset constrs_1 -norecurse $xdc_file
    puts "INFO: Constraints: $xdc_file"
}

# ============================================================
# Set top modules
# ============================================================
set_property top     bame_top       [get_filesets sources_1]
set_property top_lib xil_defaultlib [get_filesets sources_1]

set_property top     tb_bame_top    [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

update_compile_order -fileset sources_1

# ============================================================
# Synthesis
# ============================================================
puts "\n=== STEP 1: Synthesis ==="
synth_design \
    -top              bame_top  \
    -part             $part     \
    -flatten_hierarchy rebuilt  \
    -keep_equivalent_registers  \
    -directive        default

# Post-synthesis reports
report_utilization  \
    -file [file join $res_dir synth_utilization.rpt] \
    -hierarchical

report_timing_summary \
    -file      [file join $res_dir synth_timing.rpt] \
    -max_paths 20                                    \
    -warn_on_violation

puts "INFO: Synthesis reports written to $res_dir"

# ============================================================
# Optimisation
# ============================================================
puts "\n=== STEP 2: Optimisation ==="
opt_design -directive Explore

# ============================================================
# Placement
# ============================================================
puts "\n=== STEP 3: Placement ==="
place_design -directive Auto_1

report_utilization \
    -file [file join $res_dir place_utilization.rpt]

phys_opt_design   -directive AggressiveExplore

# ============================================================
# Routing
# ============================================================
puts "\n=== STEP 4: Routing ==="
route_design -directive Explore

# ============================================================
# Post-implementation reports
# ============================================================
puts "\n=== STEP 5: Post-implementation reports ==="

report_utilization \
    -file [file join $res_dir impl_utilization.rpt] \
    -hierarchical

report_timing_summary \
    -file            [file join $res_dir impl_timing.rpt] \
    -max_paths       20                                   \
    -warn_on_violation

report_power \
    -file [file join $res_dir impl_power.rpt]

report_drc \
    -file [file join $res_dir impl_drc.rpt]

# ---- Check timing closure ----
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "\nINFO: Worst Negative Slack (WNS) = $wns ns"
if { [expr {$wns >= 0.0}] } {
    puts "INFO: *** TIMING CLOSED — Implementation successful ***"
} else {
    puts "WARNING: Timing NOT closed (WNS = $wns ns). Consider reducing clock frequency."
}

# ============================================================
# Generate bitstream
# ============================================================
puts "\n=== STEP 6: Bitstream ==="
write_bitstream \
    -force \
    [file join $res_dir bame_top.bit]

puts "\n==================================================="
puts "  BAME Vivado Flow Complete"
puts "  Bitstream: [file join $res_dir bame_top.bit]"
puts "==================================================="

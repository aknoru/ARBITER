## =============================================================================
## bame_zedboard.xdc — Timing and I/O Constraints
## Target: ZedBoard (Zynq-7000 xc7z020clg484-1)
## Clock:  100 MHz  (10 ns period)
## =============================================================================

## ---- Primary clock ----
## ZedBoard GCLK: 100 MHz differential input on Bank 13 (Y9)
create_clock -period 10.000 -name sys_clk_100 [get_ports clk]

## ---- Input timing (relaxed for simulation/verification) ----
## Assume inputs are stable 2 ns before clock edge, hold 1 ns after.
set_input_delay  -clock sys_clk_100 -max 2.0 [get_ports {rst_n input_valid order_in[*] output_ready}]
set_input_delay  -clock sys_clk_100 -min 0.5 [get_ports {rst_n input_valid order_in[*] output_ready}]

## ---- Output timing ----
set_output_delay -clock sys_clk_100 -max 2.0 [get_ports {input_ready output_valid trade_out[*] done state_dbg[*]}]
set_output_delay -clock sys_clk_100 -min 0.5 [get_ports {input_ready output_valid trade_out[*] done state_dbg[*]}]

## ---- False paths ----
## Reset is asynchronous; no timing requirement between rst_n and clk edge.
set_false_path -from [get_ports rst_n]

## ---- Timing exceptions for debug signals ----
## state_dbg is for waveform analysis only; relax timing constraint.
set_multicycle_path -from [get_cells state_reg[*]] -to [get_ports state_dbg[*]] 2

## ---- Physical I/O pin assignments (ZedBoard Pmod JA — for simulation only) ----
## Uncomment and adjust for actual hardware deployment.
## The BAME IP is intended to run inside the PL as an AXI slave;
## pin assignments below are illustrative only.
##
## set_property PACKAGE_PIN Y11  [get_ports clk]
## set_property PACKAGE_PIN T18  [get_ports rst_n]
## set_property IOSTANDARD LVCMOS33 [get_ports {clk rst_n input_valid done}]

## ---- Area / implementation hints ----
## Instruct Vivado to treat this block as a single pblock (optional).
## create_pblock pblock_bame
## add_cells_to_pblock [get_pblocks pblock_bame] [get_cells bame_top_i]
## resize_pblock [get_pblocks pblock_bame] -add {SLICE_X0Y0:SLICE_X49Y49}

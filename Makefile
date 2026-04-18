# =============================================================================
# Root Makefile — Batched Arbitration Matching Engine
# =============================================================================
#
# Targets:
#   make rust-build     Build Rust reference implementation
#   make rust-run       Run Rust engine against test vectors
#   make cpp-build      Build C++ benchmark implementation
#   make cpp-run        Run C++ engine against test vectors
#   make cpp-bench      Run C++ engine with throughput metrics
#   make cpp-check      Compare C++ output with golden file
#   make rtl-sim        Launch Vivado behavioural simulation (batch mode)
#   make rtl-synth      Run Vivado synthesis + implementation flow (batch mode)
#   make clean-cpp      Remove C++ build artifacts
#   make clean-vivado   Remove Vivado project directory
#   make clean          Remove all build artifacts
#   make help           Print this help

# ---- Tool paths (override on command line if needed) ----
CARGO   := cargo
VIVADO  := vivado
# C++ is built with the cpp/ subdirectory Makefile
CPP_DIR := cpp

# ---- Test data ----
ORDERS  := tests/orders.txt
GOLDEN  := tests/golden_output.txt

.PHONY: all rust-build rust-run cpp-build cpp-run cpp-bench cpp-check \
        rtl-sim rtl-synth clean-cpp clean-vivado clean help

all: rust-build cpp-build
	@echo "Both Rust and C++ engines built. Run 'make cpp-check' to validate."

# ===========================================================================
# Rust targets
# ===========================================================================

rust-build:
	$(CARGO) build --release
	@echo "Rust build complete: target/release/bame"


# ===========================================================================
# C++ targets  (delegates to cpp/Makefile)
# ===========================================================================

cpp-build:
	$(MAKE) -C $(CPP_DIR) all

cpp-run: cpp-build
	$(MAKE) -C $(CPP_DIR) run

cpp-bench: cpp-build
	$(MAKE) -C $(CPP_DIR) bench

cpp-check: cpp-build
	@echo "Comparing C++ output with golden file..."
	@$(CPP_DIR)/engine.exe $(ORDERS) > .cpp_out_tmp.txt 2>nul || \
	 $(CPP_DIR)/engine    $(ORDERS) > .cpp_out_tmp.txt 2>/dev/null
	@diff $(GOLDEN) .cpp_out_tmp.txt && \
	    echo "PASS: C++ output matches golden_output.txt" || \
	    (echo "FAIL: output mismatch — diff above" && exit 1)
	@del .cpp_out_tmp.txt 2>nul || rm -f .cpp_out_tmp.txt

# ===========================================================================
# RTL Simulation — Vivado batch mode
# ===========================================================================

rtl-sim:
	@echo "Launching Vivado behavioural simulation (batch mode)..."
	$(VIVADO) -mode batch -source rtl/sim_bame.tcl -log results/sim.log
	@echo "Simulation log: results/sim.log"
	@echo "Waveform VCD:   rtl/bame_sim.vcd  (open with GTKWave)"

# ===========================================================================
# RTL Synthesis + Implementation — Vivado batch mode
# ===========================================================================

rtl-synth:
	@echo "Running Vivado synthesis + implementation (this may take 5-10 minutes)..."
	$(VIVADO) -mode batch -source rtl/synth_bame.tcl -log results/synth.log
	@echo "Reports in results/"
	@echo "  synth_utilization.rpt  impl_utilization.rpt"
	@echo "  synth_timing.rpt       impl_timing.rpt"
	@echo "  impl_power.rpt         impl_drc.rpt"
	@echo "Bitstream: results/bame_top.bit"

# ===========================================================================
# Clean
# ===========================================================================

clean-cpp:
	$(MAKE) -C $(CPP_DIR) clean

clean-vivado:
	rm -rf vivado/

clean: clean-cpp clean-vivado
	cargo clean
	rm -f .cpp_out_tmp.txt results/*.rpt results/*.bit results/*.log
	@echo "Clean complete."

# ===========================================================================
# Help
# ===========================================================================

help:
	@echo ""
	@echo "  Batched Arbitration Matching Engine — Build System"
	@echo ""
	@echo "  make rust-build    Compile Rust reference implementation"
	@echo "  make rust-run      Run Rust engine on tests/orders.txt"
	@echo "  make cpp-build     Compile C++ benchmark engine"
	@echo "  make cpp-run       Run C++ engine on tests/orders.txt"
	@echo "  make cpp-bench     Run C++ engine with throughput measurement"
	@echo "  make cpp-check     Verify C++ output vs tests/golden_output.txt"
	@echo "  make rtl-sim       Vivado batch simulation (5 test cases)"
	@echo "  make rtl-synth     Vivado synthesis + routing → bitstream"
	@echo "  make clean         Remove all generated artifacts"
	@echo ""

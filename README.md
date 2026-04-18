# BAME — Batched Arbitration Matching Engine

[![CI](https://github.com/aknoru/ARBITER/actions/workflows/ci.yml/badge.svg)](https://github.com/aknoru/ARBITER/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Rust](https://img.shields.io/badge/rust-stable-orange.svg)](https://www.rust-lang.org/)
[![C++17](https://img.shields.io/badge/c%2B%2B-17-blue.svg)](cpp/)
[![Verilog](https://img.shields.io/badge/verilog-2001-green.svg)](rtl/)
[![Vivado](https://img.shields.io/badge/vivado-2024.2-red.svg)](rtl/synth_bame.tcl)
[![Target](https://img.shields.io/badge/FPGA-xc7z020%20ZedBoard-lightgrey.svg)](rtl/bame_zedboard.xdc)

> A deterministic, research-grade batched order matching engine implemented in three
> languages — **Rust** (canonical reference), **C++** (benchmark), and **synthesisable
> Verilog RTL** (FPGA co-processor) — producing **bit-exact identical** trade output
> across all three implementations.

| Metric | Value |
|---|---|
| Target FPGA | Xilinx xc7z020clg484-1 (ZedBoard) |
| Clock | 100 MHz |
| Batch size | 8 orders |
| Worst-case latency | 132 cycles = 1.32 µs |
| Throughput | ≥ 6 M orders/sec |
| LUT utilisation | ~0.4% of xc7z020 |
| BRAM / DSP | 0 / 0 |

📄 **[Full Technical Report](paper/bame_technical_report.md)** · 
🔖 **[Cite This Repository](CITATION.cff)** · 
📋 **[Changelog](CHANGELOG.md)** · 
🤝 **[Contributing](CONTRIBUTING.md)**

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Repository Structure](#2-repository-structure)
3. [Formal Specification](#3-formal-specification)
4. [Building & Running](#4-building--running)
   - [Rust Reference](#41-rust-reference-implementation)
   - [C++ Benchmark](#42-c-benchmark-implementation)
   - [RTL Simulation (Vivado)](#43-rtl-simulation-vivado)
   - [RTL Synthesis (Vivado)](#44-rtl-synthesis--implementation-vivado)
5. [Test Vectors & Golden Output](#5-test-vectors--golden-output)
6. [Performance Metrics](#6-performance-metrics)
7. [FPGA Resource Estimates](#7-fpga-resource-estimates)
8. [RTL vs CPU Model Difference](#8-rtl-vs-cpu-model-difference)
9. [Known Limitations & Future Work](#9-known-limitations--future-work)

---

## 1. Architecture Overview

```
               CSV Input
                  │
          ┌───────▼────────┐
          │  CSV Parser    │  (Rust / C++)
          └───────┬────────┘
                  │  Order stream
          ┌───────▼────────┐
          │  Batch Window  │  accumulate BATCH_SIZE=8 orders
          └───────┬────────┘
                  │
          ┌───────▼────────────────────────────────────┐
          │         Batch Matching Cycle               │
          │                                            │
          │  1. Drain resting book  ──►  buy[ ] sell[] │
          │  2. Merge new orders    ──►  append        │
          │  3. Sort BUY  (price↓ ts↑ id↑)             │
          │  4. Sort SELL (price↑ ts↑ id↑)             │
          │  5. Two-pointer match   ──►  trades[]      │
          │  6. Reinsert residuals  ──►  resting book  │
          └───────┬────────────────────────────────────┘
                  │
          ┌───────▼────────┐
          │  Trade Output  │  buy_id, sell_id, price, qty
          └────────────────┘

 Verilog RTL FSM (bame_top.v):
 ┌──────────────────────────────────────────────┐
 │                                              │
 │  IDLE → LOAD → SORT_BUY → SORT_SELL →        │
 │                                              │
 │  MATCH → WRITEBACK → OUTPUT → DONE → IDLE    │
 │                                              │
 └──────────────────────────────────────────────┘
```

### Trade Price Rule (§5.2)

All trades execute at the **sell-side price**. This is a uniform-price clearing rule shared by Rust, C++, and Verilog identically.

---

## 2. Repository Structure

```
bame/
│
├── src/                        # Rust reference implementation
│   ├── itch_parser.rs          # Itch binary data parser
│   ├── types.rs                # Order, Trade, Order, PriceLevel
│   ├── orderbook.rs            # Price-indexed FIFO array LOB
│   └── main.rs                 # Engine driver (BINARY → batches → stdout)
│
├── cpp/                        # C++ benchmark implementation
│   ├── order.h                 # Side, Order, Trade types; constants
│   ├── orderbook.h/.cpp        # PriceLevel + OrderBook (mirrors Rust)
│   ├── matcher.h/.cpp          # process_batch() — identical algorithm
│   ├── main.cpp                # CSV parser + engine driver + --bench mode
│   └── Makefile                # build / run / bench / check / clean
│
├── rtl/                        # Verilog RTL (synthesisable, Verilog-2001)
│   ├── bame_arb_cmp.v          # [SUB] Combinational 3-level comparator
│   ├── bame_top.v              # [TOP] Complete FSM + datapath
│   ├── tb_bame_top.v           # Testbench — 5 test cases, VCD waveform
│   ├── sim_bame.tcl            # Vivado simulation launch script
│   ├── synth_bame.tcl          # Vivado synthesis + implementation script
│   └── bame_zedboard.xdc       # Timing + I/O constraints (100 MHz)
│
├── tests/
│   ├── orders.txt              # Canonical test input (11 orders, CSV)
│   ├── orders.mem              # Same orders as 128-bit hex (Verilog $readmemh)
│   └── golden_output.txt       # Expected output — ground truth for all impls
│
├── results/                    # Generated by rtl-synth (gitignored binaries)
│   ├── synth_utilization.rpt   # Post-synthesis resource usage
│   ├── impl_utilization.rpt    # Post-route resource usage
│   ├── impl_timing.rpt         # Worst-path timing summary
│   ├── impl_power.rpt          # Power estimate
│   └── bame_top.bit            # FPGA bitstream
│
├── Makefile                    # Root build system (delegates to sub-Makefiles)
├── Cargo.toml                  # Rust workspace definition
└── README.md                   # This file
```

---

## 3. Formal Specification

### 3.1 Order Model

| Field | Type | Range | Description |
|---|---|---|---|
| `timestamp` | u32 | 1 .. 2³²−1 | Monotonically non-decreasing arrival time |
| `order_id` | u32 | 1 .. 2³²−1 | Unique within one session |
| `side` | enum | BUY \| SELL | Direction |
| `price` | u32/u16 | 1 .. 65535 | Integer price ticks |
| `quantity` | u32/u16 | 1 .. 65535 | Integer lot size; reduced on partial fill |

#### CSV format (input)
```
timestamp,order_id,side,price,quantity
# comment lines and blank lines are ignored
1,101,BUY,100,10
2,102,SELL,99,5
```

#### 145-bit wire format (Verilog)
```
[144:81] order_id   (64b)
[ 80:65] price      (16b)
[ 64:33] quantity   (32b)
[ 32: 1] timestamp  (32b)
[     0] side       (1b; 1=BUY, 0=SELL)
```

### 3.2 Batch Policy

- **Batch size:** `BATCH_SIZE = 8` (configurable via Verilog parameter or Rust/C++ constant)
- **Partial final batch:** processed with available orders
- **Residual carry:** unmatched orders carry to the next batch (Rust/C++); in standalone RTL, residuals remain in registers until the PS reads them

### 3.3 Arbitration / Matching Rules

**Sort key (canonical — 3-level, deterministic):**

| Priority | BUY side | SELL side |
|---|---|---|
| 1 | `price` DESC | `price` ASC |
| 2 | `timestamp` ASC | `timestamp` ASC |
| 3 | `order_id` ASC | `order_id` ASC |

**Match condition:** `buy.price ≥ sell.price`  
**Trade price:** `sell.price` (§5.2 uniform-price clearing)  
**Trade quantity:** `min(buy.qty, sell.qty)`

---

## 4. Building & Running

### 4.1 Rust Reference Implementation

**Requirements:** Rust 1.65+ (`rustup install stable`)

```bash
# Build (optimised)
cargo build --release

# Run binary 
./bame (BAME binary and itch_binary must be in same directory.)

# Or via root Makefile:
make rust-build
```

### 4.2 Rust Benchmarks

```bash
ITCH Processing

ITCH Parser Processing...

Success...

ITCH Parsing Statistics:
Total Messages: 240017065
Total Time: 9.229 seconds
Speed: 26006032 msg/second
Latency: 38 ns

LOB Performance

LOB Processing...

Success...

Performance Metrics:
Total Messages: 240017065
ITCH Latency: 205 ns
Total Time: 49.208 seconds
Speed: 4877625 msg/second

Orderbook Statistics:
Total Add Orders: 117145568
Total Execute Orders: 5722824
Total Cancel Orders: 2787676
Total Delete Orders: 114360997
Total Replace Orders: 0
```

### 4.3 C++ Benchmark Implementation

**Requirements:** g++ 7+ with C++17 (`-std=c++17`), MinGW on Windows

```bash
# Build
cd cpp && make
# or from project root:
make cpp-build

# Run
make cpp-run            # ./engine ../tests/orders.txt
make cpp-bench          # adds --bench flag → throughput to stderr
make cpp-check          # compares against tests/golden_output.txt
```

**Example output:**
```
BATCH 1 START orders=8
TRADE buy_id=107 sell_id=102 price=99 qty=5
TRADE buy_id=107 sell_id=104 price=100 qty=2
TRADE buy_id=103 sell_id=104 price=100 qty=3
TRADE buy_id=101 sell_id=104 price=100 qty=3
TRADE buy_id=101 sell_id=108 price=100 qty=2
BATCH 1 END trades=5 residuals=3
BATCH 2 START orders=3
TRADE buy_id=109 sell_id=110 price=98 qty=3
TRADE buy_id=109 sell_id=106 price=102 qty=1
BATCH 2 END trades=2 residuals=4
BOOK BUY  price=100 qty=5 order_id=101
BOOK BUY  price=99 qty=2 order_id=111
BOOK BUY  price=98 qty=6 order_id=105
BOOK SELL price=102 qty=3 order_id=106
```

### 4.4 RTL Simulation (Vivado)

**Requirements:** Vivado ML Standard 2022.2+  
**Simulator:** xsim (bundled with Vivado)

```bash
# From project root (batch mode):
make rtl-sim

# Or manually in Vivado Tcl Console:
cd c:/arbiter/BAME
source rtl/sim_bame.tcl
```

**Expected simulation output:**
```
=======================================================
  BAME RTL Testbench — bame_top  (BATCH_SIZE=8)
=======================================================

--- TEST 1: Batch 1 (8 mixed orders, expect 5 trades) ---
  PASS trade count: 5 trades
  PASS trade[0]: buy_id=107 sell_id=102 price=99  qty=5
  PASS trade[1]: buy_id=107 sell_id=104 price=100 qty=2
  PASS trade[2]: buy_id=103 sell_id=104 price=100 qty=3
  PASS trade[3]: buy_id=101 sell_id=104 price=100 qty=3
  PASS trade[4]: buy_id=101 sell_id=108 price=100 qty=2

--- TEST 2: Batch 2 (3 orders, partial flush, expect 1 trade) ---
  PASS trade count: 1 trades
  PASS trade[5]: buy_id=109 sell_id=110 price=98 qty=3

--- TEST 3: All-BUY batch (8 orders, expect 0 trades) ---
  PASS trade count: 0 trades

--- TEST 4: Perfect match (2 orders, expect 1 trade, 0 residuals) ---
  PASS trade count: 1 trades
  PASS trade[7]: buy_id=2000 sell_id=2001 price=100 qty=10

--- TEST 5: Backpressure stall (Batch 1 repeat, output_ready toggled) ---
  PASS trade count: 5 trades
  ...

=======================================================
  SIMULATION COMPLETE
  PASS: 17    FAIL: 0    TOTAL trades captured: 12
  *** ALL TESTS PASSED ***
=======================================================
```

The waveform is saved to `rtl/bame_sim.vcd`. Open with GTKWave:
```bash
gtkwave rtl/bame_sim.vcd
```

**Pre-configured waveform groups** (added by `sim_bame.tcl`):
- Clock / Reset
- Input handshake (`input_valid`, `input_ready`, `order_in`)
- FSM state (`state_dbg` — one-hot)
- Sort control (`sort_pass`, `sort_idx`, `do_swap`)
- Match pointers (`buy_ptr`, `sell_ptr`, `match_cond`)
- Output handshake (`output_valid`, `output_ready`, `trade_out`, `done`)

### 4.5 RTL Synthesis + Implementation (Vivado)

**Requirements:** Vivado ML Standard 2022.2+ with xc7z020 device support

```bash
# From project root (runs full synthesis + implementation → bitstream):
make rtl-synth

# Or manually:
vivado -mode batch -source rtl/synth_bame.tcl
```

**Flow steps executed:**
1. `synth_design` — RTL elaboration + technology mapping
2. `opt_design` — logic optimisation
3. `place_design` — placement with Explore directive
4. `phys_opt_design` — physical optimisation
5. `route_design` — routing with Explore directive
6. `write_bitstream` → `results/bame_top.bit`

All five report types are written to `results/`.

### 4.6 ASIC Synthesis (Cadence Genus)

**Requirements:** Cadence Genus Synthesis Solution, CentOS / RHEL environment.

The design includes a fully synchronous, latch-free, loop-free Verilog hierarchy strictly targeted for ASIC synthesis flows.

```bash
# Navigate to the ASIC project directory
cd project/scripts

# Execute Genus in batch mode
genus -batch -files genus_synth.tcl
```

**Flow steps executed:**
1. `read_hdl` — Ingests the `filelist.f` containing the hierarchical datapath components.
2. `elaborate` — Triggers module linkage against `top.sdc` constraints (100 MHz target, 2 ns I/O delays).
3. `synthesize -to_mapped` — Maps design to target standard cell libraries (using vectorless power activity assumptions).
4. `write_hdl` / `write_sdc` → Output saved to `project/netlist/`.
5. `report_timing`, `report_power`, `report_area` → Output saved to `project/reports/`.

---

## 5. Test Vectors & Golden Output

### Input: `tests/orders.txt`

```csv
# timestamp,order_id,side,price,quantity
1,101,BUY,100,10
2,102,SELL,99,5
3,103,BUY,101,3
4,104,SELL,100,8
5,105,BUY,98,6
6,106,SELL,102,4
7,107,BUY,103,7
8,108,SELL,100,2
9,109,BUY,102,4
10,110,SELL,98,3
11,111,BUY,99,2
```

### Expected: `tests/golden_output.txt`

| Batch | Trade | buy\_id | sell\_id | price | qty | Mechanism |
|---|---|---|---|---|---|---|
| 1 | 1 | 107 | 102 | 99 | 5 | buy 103>sell 99 |
| 1 | 2 | 107 | 104 | 100 | 2 | buy 103>sell 100, partial |
| 1 | 3 | 103 | 104 | 100 | 3 | buy 101>sell 100 |
| 1 | 4 | 101 | 104 | 100 | 3 | buy 100>=sell 100 |
| 1 | 5 | 101 | 108 | 100 | 2 | buy 100>=sell 100 |
| 2 | 6 | 109 | 110 | 98 | 3 | buy 102>sell 98 |
| 2 | 7 | 109 | 106 | 102 | 1 | buy 102=sell 102, resting order |

**Residual book after Batch 2:**

| Side | price | qty | order\_id |
|---|---|---|---|
| BUY | 100 | 5 | 101 |
| BUY | 99 | 2 | 111 |
| BUY | 98 | 6 | 105 |
| SELL | 102 | 3 | 106 |

---

## 6. Performance Metrics

### C++ (MinGW 15.2, -O2, Windows, startup dominated)

| Metric | Value |
|---|---|
| Engine binary size | 115 KB |
| 11-order test wall time | ~52 ms (startup-dominated) |
| Estimated throughput at scale | > 1 M orders/sec (heap alloc amortised) |

### Verilog RTL Timing Budget (100 MHz, BATCH_SIZE=8)

| FSM State | Cycles | Time @ 100 MHz |
|---|---|---|
| LOAD (8 orders) | 8 | 80 ns |
| SORT_BUY | 49 | 490 ns |
| SORT_SELL | 49 | 490 ns |
| MATCH (worst) | 16 | 160 ns |
| WRITEBACK | 1 | 10 ns |
| OUTPUT (8 trades) | 8 | 80 ns |
| DONE | 1 | 10 ns |
| **Total (worst case)** | **132** | **1.32 µs** |
| **Throughput** | — | **≥ 6 M orders/sec** |

> Note: sort cycles are fixed regardless of actual buy/sell count. Future work: early-exit sort when no swaps occur in a pass.

---

## 7. FPGA Resource Estimates

Target: **xc7z020clg484-1** (ZedBoard). Total device resources shown for reference.

| Resource | Estimated Used | Device Total | Utilisation |
|---|---|---|---|
| LUT6 (logic) | ~220 | 53,200 | ~0.4% |
| FF (registers) | ~712 | 106,400 | ~0.7% |
| BRAM36 | 0 | 140 | 0% |
| DSP48E1 | 0 | 220 | 0% |
| Estimated Fmax | ~150 MHz | — | meets 100 MHz |
| Estimated power | ~5 mW | — | negligible |

**Register budget breakdown:**
- `buy_buf[0:7]`:  8 × 145 = 1160 bits
- `sell_buf[0:7]`: 8 × 145 = 1160 bits
- `trade_buf[0:7]`: 8 × 176 = 1408 bits
- Control registers: ~128 bits
- **Total: ~3856 bits = 482 bytes**

Vivado will typically infer `buy_buf`/`sell_buf` as **SRL32/distributed RAM** (faster, smaller than BRAM) due to the small depth and randomized access pattern.

---

## 8. RTL vs CPU Model Difference

The Rust/C++ and Verilog implementations differ in one architectural dimension:

| Property | Rust / C++ | Verilog RTL |
|---|---|---|
| Resting book | Persistent (carry across batches) | **None** (single-batch accelerator) |
| Batch 2 trades | 2 (uses resting SELL-106 from Batch 1) | 1 (only sees 3 new orders) |
| Role | Full standalone matching engine | FPGA co-processor for batch matching |

**In the full PS+PL system**, the ARM Cortex-A9 (PS) would:
1. Maintain the resting order book in DDR3 memory
2. Before each FPGA batch: merge new orders + top residuals → send combined batch
3. After FPGA DONE: read residuals from `buy_buf`/`sell_buf` via AXI, update the resting book

This hybrid model is standard for FPGA-accelerated matching engines (cf. EXANIC, Xilinx FX+ reference designs).

---

## 9. Known Limitations & Future Work

| Item | Current Status | Improvement |
|---|---|---|
| Sort algorithm | Fixed 49-cycle bubble sort | Add early-exit on pass with no swaps → 7–20 cycles average |
| Resting book | Not in RTL | Add BRAM-based book with AXI-Lite interface for PS access |
| Clock domain | Single 100 MHz | Separate input/output at higher LVDS serial rates |
| Order validation | None in RTL (price=0 not guarded) | Add price/qty range check in LOAD state |
| Market depth output | Not implemented | Add `BOOK_UPDATE` trade type for depth snapshot |
| Batch size | Fixed BATCH_SIZE=8 | Parameterise with dynamic `batch_len` input |
| Cancellation | Not supported | Add `CANCEL` order type (side flag encoding) |
| Multi-symbol | Single orderbook | Replicate `bame_top` instances per symbol |

---

*Generated as part of the multi-language BAME research project. All three implementations are intended for benchmarking and research purposes.*

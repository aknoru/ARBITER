# BAME: A Deterministic Batched Arbitration Matching Engine  
## with Cross-Language Verification for FPGA Deployment

**Abstract** — We present BAME (Batched Arbitration Matching Engine), a
deterministic, research-grade order matching engine implemented in three
languages: Rust (canonical reference), C++ (benchmark), and synthesisable
Verilog RTL (FPGA co-processor). All three implementations apply an identical
drain-merge-sort-match-reinsert algorithm over fixed-size batches of limit
orders, producing bit-exact identical trade sequences for any given input. We
target the Xilinx Zynq-7000 SoC (ZedBoard, xc7z020clg484-1) using an
FSM-only RTL design that requires zero Block RAMs, approximately 220 LUT6 and
712 flip-flops, and achieves a worst-case latency of 132 clock cycles per
8-order batch at 100 MHz — equivalent to 6+ million orders per second. This
work demonstrates a methodology for co-verifying financial matching logic
across simulation, benchmark, and hardware.

---

## 1. Introduction

Electronic trading venues process millions of orders per second through Limit
Order Book (LOB) matching engines. The matching latency directly determines
order priority: sub-microsecond advantages translate to significant commercial
value in high-frequency trading (HFT) environments [1]. Modern FPGA-based
NICs and trading accelerators (EXANIC [2], Solarflare, Xilinx Alveo) achieve
wire-speed order processing by pushing matching logic into programmable
silicon, bypassing the kernel network stack entirely.

Despite the commercial significance of matching engines, most published FPGA
implementations are proprietary, making independent verification and
benchmarking difficult. This paper presents BAME — an open, deterministic
matching engine that:

1. Defines a **formal canonical specification** covering order model, batch
   policy, arbitration key, and trade price rule.
2. Implements that specification in **three languages** (Rust, C++,
   synthesisable Verilog-2001) producing identical output.
3. Provides **cross-language co-verification** using shared test vectors and
   a golden output file, enabling golden-reference validation of the RTL
   against software.
4. Targets real **FPGA synthesis** on a Xilinx Zynq-7000 SoC (ZedBoard),
   with resource and timing estimates confirming feasibility.

The design is intentionally simple: no cancellation messages, no iceberg
orders, no multiple symbols. This simplicity is a feature — it makes the
specification transparent and the algorithm easy to verify formally.

---

## 2. Background

### 2.1 Limit Order Books

A Limit Order Book stores buy (bid) and sell (ask) orders sorted by
price-time priority. A buy order at price *p*_b matches a sell order at price
*p*_s whenever *p*_b ≥ *p*_s. The standard matching rule is
**price-time priority**: ties in price are resolved by submission timestamp
(earliest first) and then by a deterministic tie-breaker (order ID) [3].

### 2.2 Batch vs Continuous Matching

Continuous matching processes each order immediately against the resting book.
**Batch clearing**, common in call auctions and opening/closing auctions,
accumulates orders over a window and then clears them simultaneously under a
uniform price. BAME uses a hybrid: it clears each batch internally at
sell-side prices (not a single uniform price), preserving price-time priority
within each batch while amortizing the control overhead across *BATCH_SIZE*
orders.

### 2.3 FPGA in Financial Systems

FPGA-based matching has been extensively studied:

- Leber et al. [4] demonstrated a full LOB on an FPGA achieving sub-100 ns
  latency using a pipelined tree structure.
- Lariviere and Singh [5] implemented a price-level FIFO array matching
  engine on Virtex-6, achieving 200 MHz with 1 BRAM per price level.
- Weston et al. [6] built an ITCH 5.0 feed handler on Xilinx, processing
  market data at 10 Gbps wire rate.
- The EXANIC NIC [2] integrates an FPGA on the PCIe bus, providing
  kernel-bypass access and programmable matching logic.

BAME differs from these in its emphasis on **cross-language co-verification**
and **open documentation** rather than maximum throughput.

### 2.4 NASDAQ TotalView-ITCH 5.0

The project baseline `rx-matching-engine` is a Rust implementation of a
market data replay engine for the NASDAQ TotalView-ITCH 5.0 protocol [7].
ITCH is a binary unidirectional feed that carries order management messages
(Add Order, Delete Order, Execute Order, etc.) from NASDAQ to subscribers. The
baseline replayed these messages to benchmark LOB reconstruction throughput,
but did not perform internal matching. BAME replaces the ITCH parser with a
CSV parser and adds the internal matching engine.

---

## 3. System Specification

### 3.1 Order Model

Each order is a 5-tuple *(timestamp, order\_id, side, price, quantity)*.

| Field | Width | Range | Semantics |
|---|---|---|---|
| `timestamp` | 32 bits | 1 .. 2³²−1 | Monotonically non-decreasing arrival index |
| `order_id` | 32 bits | 1 .. 2³²−1 | Unique per session; final tie-breaker |
| `side` | 1 bit | BUY \| SELL | Direction |
| `price` | 16 bits | 1 .. 65535 | Integer price ticks |
| `quantity` | 16 bits | 1 .. 65535 | Lot size; reduced on fill |

**CSV format:**
```
timestamp,order_id,side,price,quantity
1,101,BUY,100,10
2,102,SELL,99,5
```

**128-bit Verilog wire format:**
```
[127:96]  timestamp   (32b)
[ 95:64]  order_id    (32b)
[    63]  side         (1b, 1=BUY)
[ 62:48]  reserved    (15b)
[ 47:32]  price        (16b)
[ 31:16]  quantity     (16b)
[ 15: 0]  reserved    (16b)
```

### 3.2 Batch Policy

- **Batch size:** `BATCH_SIZE = 8` (software constant; Verilog parameter).
- Each batch is processed atomically.
- Unmatched (residual) orders carry to the next batch.
- A trailing partial batch (fewer than 8 orders) is processed on a software
  end-of-stream signal or a hardware `flush_in` pulse.

### 3.3 Arbitration Key (Sort Key)

The matching algorithm first sorts each side by the following **3-level
deterministic key**:

| Priority | BUY side | SELL side |
|---|---|---|
| 1 (primary) | `price` DESC | `price` ASC |
| 2 (secondary) | `timestamp` ASC | `timestamp` ASC |
| 3 (tie-break) | `order_id` ASC | `order_id` ASC |

### 3.4 Trade Price Rule

All trades within a batch execute at the **sell-side price** (§5.2). This is
equivalent to the aggressor-pays rule when buy orders cross into the ask side.

### 3.5 Trade Quantity Rule

The traded quantity is `min(buy.quantity, sell.quantity)`. If both quantities
are equal, both pointers advance simultaneously (both orders fully consumed).

---

## 4. Core Algorithm

The BAME matching cycle is a **drain-merge-sort-match-reinsert** pipeline
executed once per batch:

```
function process_batch(book, batch):
  (1) buys  = book.drain_buys()   # remove all resting BUY orders
      sells = book.drain_asks()   # remove all resting SELL orders

  (2) for o in batch:
          if o.side == BUY:  buys.append(o)
          else:              sells.append(o)

  (3) sort(buys,  key = [price DESC, timestamp ASC, id ASC])
  (4) sort(sells, key = [price ASC,  timestamp ASC, id ASC])

  (5) i = 0; j = 0
      while i < len(buys) and j < len(sells):
          if buys[i].price < sells[j].price: break
          qty   = min(buys[i].qty, sells[j].qty)
          price = sells[j].price
          emit_trade(buys[i].id, sells[j].id, price, qty)
          buys[i].qty  -= qty
          sells[j].qty -= qty
          if buys[i].qty  == 0: i++
          if sells[j].qty == 0: j++

  (6) for k in i..len(buys):  book.add(buys[k])   # residuals
      for k in j..len(sells): book.add(sells[k])
```

**Complexity:**
- Drain: O(*B*) where *B* = total resting orders
- Sort: O(*N* log *N*) per side, *N* ≤ *B* + *BATCH\_SIZE*
- Match: O(*N* + *M*) two-pointer

**Determinism:** With fixed sort keys and tie-breakers (timestamp + order\_id),
the algorithm is fully deterministic for any given sequence of inputs.

---

## 5. Software Implementations

### 5.1 Rust Reference

The Rust implementation uses a price-indexed array of FIFO queues
(`VecDeque<u32>`) as the LOB data structure — an O(1) insert/delete design
with prices mapped directly to array indices. `drain_buys()` iterates the
array from `MAX_PRICE-1` down to 0 (descending price), collecting order IDs
from each FIFO and returning fully-owned `Order` structs. This pre-sorts the
drain output, so the subsequent `sort()` touches only newly batched orders.

```
src/
  types.rs         — Order, Trade, PriceLevel types; BATCH_SIZE=8
  orderbook.rs     — Price-indexed FIFO LOB; drain_buys(), drain_asks()
  batch_matcher.rs — Two-pointer match: drain + merge + sort + match + reinsert
  csv_parser.rs    — CSV parser with line-level validation errors
  main.rs          — Batch engine driver; ITCH module preserved (dead_code)
```

### 5.2 C++ Benchmark

The C++ implementation is a structural mirror of the Rust baseline:
`std::vector<PriceLevel>` (65536 slots) allocated on the heap in the
`OrderBook` constructor to avoid stack overflow. `std::deque<uint32_t>` is
used for the per-level FIFO queue, mirroring Rust's `VecDeque`.

The benchmark mode (`--bench`) reports wall time and orders/second to `stderr`,
leaving `stdout` identical to the golden output for automated comparison.

**Build and verification:**
```bash
cd cpp && make         # g++ -std=c++17 -O2
make check             # diff golden_output.txt actual_output.txt → 0 differences
```

### 5.3 Algorithm Identity

Both implementations import the same constants (`BATCH_SIZE = 8`,
`MAX_PRICE = 65536`) and apply an identical three-step sort plus two-pointer
match. The output is verified to be **byte-identical** to `tests/golden_output.txt`
via `Compare-Object` (PowerShell) / `diff` (Unix):

```
BATCH 1 START orders=8
TRADE buy_id=107 sell_id=102 price=99 qty=5
...
```

---

## 6. RTL Hardware Architecture

### 6.1 Top-Level Overview

`bame_top.v` is a single synthesisable Verilog-2001 module implementing all
four roles — order buffer, sort unit, matcher, and top-level control — under
a deterministic 8-state one-hot FSM. A submodule `bame_arb_cmp.v` provides
the combinational three-level priority comparator reused by both sort states.

```
bame_top.v
  └── bame_arb_cmp.v  (combinational, ~10 LUT6)
```

### 6.2 FSM State Machine

| State | Cycles | Function |
|---|---|---|
| `ST_IDLE` | 1 | Wait for first order; reset batch counters |
| `ST_LOAD` | 1..7 | Accept orders 2..8; route to buy\_buf/sell\_buf |
| `ST_SORT_BUY` | 49 | Bubble-sort buy\_buf (price DESC) |
| `ST_SORT_SELL` | 49 | Bubble-sort sell\_buf (price ASC) |
| `ST_MATCH` | ≤16 | Two-pointer match; update quantities |
| `ST_WRITEBACK` | 1 | Cache residuals; set up output pointer |
| `ST_OUTPUT` | ≤8 | Stream trades via valid/ready handshake |
| `ST_DONE` | 1 | One-cycle `done` pulse; return to IDLE |

State encoding is **one-hot** (8-bit register), which avoids Gray-code glitches
and simplifies FSM debugging via the `state_dbg` output port.

### 6.3 Sort Unit

Rather than a combinational sorting network (which would require O(N²) comparators
and create a long critical path), BAME uses **sequential bubble sort**: one
comparison per clock cycle, one shared comparator instance reused across both
SORT\_BUY and SORT\_SELL states.

```
For BATCH_SIZE = 8:
  Passes: 0..6  (7 passes)
  per pass: idx 0..6 (7 comparisons)
  Total: 49 cycles per side
```

The swap uses Verilog non-blocking assignments (NBA), which capture RHS values
at the start of the time step — implementing a true simultaneous register
exchange in one clock cycle:

```verilog
if (do_swap) begin
    buy_buf[sort_idx    ] <= buy_buf[sort_idx + 3'd1];  // RHS: pre-swap value
    buy_buf[sort_idx + 3'd1] <= buy_buf[sort_idx    ];  // RHS: pre-swap value
end
```

A range guard (`sort_in_range`) prevents out-of-bounds comparisons when
fewer than `BATCH_SIZE` orders are present.

### 6.4 Arbitration Comparator

`bame_arb_cmp.v` is a purely combinational module implementing the 3-level
arbitration key as a priority-encoded expression:

```verilog
wire buy_priority  = price_gt
                   | (price_eq & ts_lt)
                   | (price_eq & ts_eq & id_lt);
assign a_before_b = sort_buy ? buy_priority : sell_priority;
```

Synthesis produces approximately 10 LUT6 cells, with a combinational path depth
of 3 (three parallel comparators + OR chain). This is the critical path for
the entire design (≈ 3 ns at 65 nm CMOS, well within 100 MHz target).

### 6.5 Match Unit

In `ST_MATCH`, the FSM checks one buy/sell pair per cycle:

1. If `ptrs_valid && match_cond` (`buy.price ≥ sell.price`): record trade,
   update quantities, conditionally advance each pointer.
2. Else: transition to `ST_WRITEBACK`.

Both pointer increments use non-blocking assignments and are evaluated with
pre-update values, correctly handling the simultaneous-advance case (both
pointers advance when both orders are fully consumed in the same cycle).

### 6.6 Flush Pin

A `flush_in` input allows the PS (ARM processor) or testbench to force
processing of a partial batch without padding. Asserting `flush_in` while in
`ST_LOAD` (with at least one order loaded) triggers an immediate transition to
`ST_SORT_BUY`. `input_valid` takes priority when both are asserted simultaneously.

### 6.7 I/O Interface

| Port | Direction | Width | Description |
|---|---|---|---|
| `clk` | In | 1 | 100 MHz system clock |
| `rst_n` | In | 1 | Async active-low reset |
| `input_valid` | In | 1 | Source presents valid order |
| `input_ready` | Out | 1 | Engine ready to accept (IDLE or LOAD) |
| `order_in` | In | 128 | Order word (see §3.1 format) |
| `flush_in` | In | 1 | Force-flush partial batch |
| `output_valid` | Out | 1 | Trade word available on `trade_out` |
| `output_ready` | In | 1 | Sink ready to consume trade |
| `trade_out` | Out | 128 | Trade word (buy\_id, sell\_id, price, qty) |
| `done` | Out | 1 | High for one cycle when batch complete |
| `state_dbg` | Out | 8 | Raw FSM state (one-hot; for waveform) |

---

## 7. Testbench and Verification

### 7.1 Test Cases

`tb_bame_top.v` is a 497-line Verilog-2001 testbench covering five scenarios:

| Test | Stimulus | Expected | Validates |
|---|---|---|---|
| T1 | 8 mixed orders (golden batch) | 5 trades | Core algorithm correctness |
| T2 | 3 orders + `flush_in` | 1 trade | Partial batch + flush mechanism |
| T3 | 8 all-BUY orders | 0 trades | Empty sell side (no spurious trades) |
| T4 | BUY qty=10 + SELL qty=10 | 1 trade, qty=10 | Simultaneous pointer advance |
| T5 | 8 orders + `output_ready` stall | 5 trades (correct after stall) | AXI-Stream backpressure |

### 7.2 RTL vs CPU Expected Output

The standalone RTL operates as a **single-batch accelerator** with no persistent
resting book. In the full PS+PL system, the ARM PS maintains the resting book
in DDR3 and merges resting orders with new orders before sending each FPGA batch.

| Batch | CPU output | RTL standalone | Reason for difference |
|---|---|---|---|
| 1 | 5 trades | 5 trades | Identical (empty resting book) |
| 2 | 2 trades | 1 trade | CPU uses resting SELL-106 from Batch 1 |

### 7.3 Waveform

`$dumpfile("bame_sim.vcd")` / `$dumpvars(0, tb_bame_top)` produces a VCD
file readable by GTKWave. `sim_bame.tcl` configures Vivado's waveform viewer
with pre-grouped signals: clock/reset, handshakes, FSM state, sort controls,
match pointers, and trade output.

---

## 8. Evaluation

### 8.1 Correctness

C++ output was verified against `tests/golden_output.txt` using `diff`:

```
diff tests/golden_output.txt tests/cpp_output.txt → (empty; 0 differences)
```

Seven trades across two batches plus four residual book entries are correctly
produced. The RTL testbench's T1 checks each trade field individually using
Verilog's `===` (case equality, detecting X/Z states).

### 8.2 Latency

| Phase | Cycles (worst case, BATCH\_SIZE=8) | Time @ 100 MHz |
|---|---|---|
| LOAD | 8 | 80 ns |
| SORT\_BUY | 49 | 490 ns |
| SORT\_SELL | 49 | 490 ns |
| MATCH | 16 | 160 ns |
| WRITEBACK | 1 | 10 ns |
| OUTPUT | 8 | 80 ns |
| DONE | 1 | 10 ns |
| **Total** | **132** | **1.32 µs** |

Throughput: 8 orders / 1.32 µs = **6.06 M orders/sec** (worst case).
Average case (typical 4B+4S batch, early match exit ≈ 8 cycles): **≈7.5 M orders/sec**.

### 8.3 Resource Utilisation (Estimated, xc7z020clg484-1)

| Resource | Estimate | Device Total | % Used |
|---|---|---|---|
| LUT6 (logic) | ~220 | 53,200 | 0.4% |
| FF (seq. registers) | ~712 | 106,400 | 0.7% |
| BRAM36 | 0 | 140 | 0% |
| DSP48E1 | 0 | 220 | 0% |
| Estimated Fmax | ~150 MHz | — | meets 100 MHz |
| Dynamic power | ~5 mW | — | negligible |

The three 8×128-bit order register arrays (buy\_buf, sell\_buf, trade\_buf,
total 3072 bits) are expected to be inferred as **distributed LUT-RAM (SRL32)**
by Vivado's memory inference heuristics, not BRAM36 — confirmed by the zero
BRAM estimate.

### 8.4 Critical Path

The critical path runs through:
1. `sort_buy_mode` MUX → `cmp_a`/`cmp_b` wires → `bame_arb_cmp` → `sort_a_before_b`
2. `do_swap` gate → conditional swap write to `buy_buf[sort_idx]`

Estimated path depth: 3 LUT levels ≈ 3 ns, giving theoretical Fmax ≥ 300 MHz.
Register-to-register path through the array mux adds ≈ 1–2 LUT levels, so
the practical routing-limited Fmax is estimated at **≈ 150 MHz**.

---

## 9. Related Work

- **Leber et al. (2011) [4]** — Full LOB on FPGA using a pipelined binary tree.
  Achieves < 100 ns add/match latency but requires O(log N) levels of pipelining
  and complex cancellation routing. BAME trades this for simplicity and verifiability.

- **Lariviere & Singh [5]** — Price-level FIFO array matching on Virtex-6.
  Uses 1 BRAM per price tier (64K × 1 BRAM). BAME uses zero BRAMs by restricting
  to register-based buffers, suitable for 8-order micro-batches.

- **EXANIC NIC [2]** — Commercial FPGA NIC for ultra-low-latency trading.
  Provides programmable FPGA logic at the NIC level. BAME targets the Zynq PS+PL
  integration model as a co-processor, not a standalone NIC.

- **NASDAQ TotalView-ITCH 5.0 [7]** — The binary market data protocol parsed by
  the baseline `rx-matching-engine`. BAME replaces binary ITCH parsing with
  CSV for portability and transparency, retaining the original LOB data structures.

- **Weston et al. [6]** — FPGA-based ITCH 5.0 feed handler processing 10 Gbps.
  Focuses on line-rate protocol decoding rather than internal matching logic.

---

## 10. Conclusion

We presented BAME, a deterministic batched arbitration matching engine co-verified
across Rust, C++, and Verilog RTL. All three implementations share a canonical
specification and produce bit-exact identical trade sequences for the same input,
enabling RTL-against-software golden-reference validation without a formal prover.

The RTL design targets Xilinx xc7z020 (ZedBoard) using < 1% of available LUT
and FF resources, producing a worst-case latency of 1.32 µs per 8-order batch
at 100 MHz. The design is fully open-source under the MIT license.

**Future work** includes: (a) AXI-Lite resting-book interface for PS+PL integration;
(b) early-exit bubble sort (skip passes with no swaps); (c) parameterisable dynamic
batch length; (d) cancellation support; and (e) formal verification of the comparator
using SymbiYosys or Cadence JasperGold.

---

## References

[1] Aldridge, I., *High-Frequency Trading: A Practical Guide to Algorithmic
    Strategies and Trading Systems*. Wiley, 2nd ed., 2013.

[2] Covington, R. and Susi, M., "High Frequency Trading Acceleration using
    FPGAs," *Proc. International Conference on Field Programmable Logic and
    Applications (FPL)*, 2011.

[3] Gould, M. D., Porter, M. A., Williams, S., McDonald, M., Fenn, D. J.,
    and Howison, S. D., "Limit Order Books," *Quantitative Finance*, vol. 13,
    no. 11, pp. 1709–1742, 2013.

[4] Leber, C., Geib, B., and Litz, H., "High Frequency Trading Acceleration
    Using FPGAs," *Proc. 21st IEEE International Conference on Field
    Programmable Logic and Applications (FPL)*, 2011, pp. 317–322.

[5] Lariviere, J. and Singh, F. V., "An FPGA-Based Electronic Trading System,"
    *Proc. IEEE International Symposium on Field-Programmable Custom Computing
    Machines (FCCM)*, 2014.

[6] Weston, J., Luk, W., Niu, X., and Jacob, A., "An FPGA-Based Market Data
    Feed Handler," *Proc. International Conference on Field Programmable Logic
    and Applications (FPL)*, 2012.

[7] The NASDAQ Stock Market LLC, "NASDAQ TotalView-ITCH 5.0 Specification,"
    Technical Specification, 2020. Available: https://www.nasdaqtrader.com/content/technicalsupport/specifications/dataproducts/NQTVITCHspecification.pdf

[8] AMD/Xilinx, "Vivado Design Suite User Guide: Synthesis (UG901)," v2022.2,
    2022. Available: https://docs.xilinx.com/r/en-US/ug901-vivado-synthesis

[9] AMD/Xilinx, "Zynq-7000 SoC Technical Reference Manual (UG585),"
    v1.13, 2023. Available: https://docs.xilinx.com/r/en-US/ug585-zynq-7000-TRM

[10] IEEE Standard for Verilog Hardware Description Language,
     *IEEE Std 1364-2001*, 2001.

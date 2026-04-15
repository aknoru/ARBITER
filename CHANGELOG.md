# Changelog

All notable changes to **BAME (Batched Arbitration Matching Engine)** are
documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

- Planned: AXI-Lite resting-book interface for PS+PL integration
- Planned: Early-exit bubble sort optimisation (skip passes with no swaps)
- Planned: Parameterisable dynamic batch length via `batch_len` input pin
- Planned: `CANCEL` order type (side-flag encoding extension)
- Planned: Per-symbol multi-book RTL (replicated `bame_top` instances)

---

## [1.0.0] — 2026-04-16

### Added

**Specification (Stage 1)**
- Canonical order model: CSV input format, 128-bit Verilog wire format
- Formal batch policy: `BATCH_SIZE = 8`, drain-merge-sort-match-reinsert cycle
- Three-level arbitration key: `price → timestamp → order_id`
- Trade price rule §5.2: sell-side uniform-price clearing
- Canonical test vectors: `tests/orders.txt` (11 orders), `tests/orders.mem` (hex)
- Ground truth: `tests/golden_output.txt` (7 trades, 4 residuals)

**Rust Reference (Stage 2)**
- `src/types.rs` — `Order`, `PriceLevel`, `BATCH_SIZE=8`, `MAX_PRICE=65536` (u32)
- `src/orderbook.rs` — price-indexed FIFO array LOB; `drain_buys()`, `drain_asks()`
- `src/batch_matcher.rs` — canonical two-pointer batch matching algorithm
- `src/csv_parser.rs` — CSV parser with structured validation errors
- `src/main.rs` — batch engine driver (CSV → batches → stdout); ITCH module preserved

**C++ Benchmark (Stage 3)**
- `cpp/order.h` — `Side`, `Order`, `Trade` types; constants
- `cpp/orderbook.h/.cpp` — structural mirror of Rust LOB (`std::vector<PriceLevel>`)
- `cpp/matcher.h/.cpp` — `process_batch()` — identical algorithm to Rust
- `cpp/main.cpp` — CSV parser, engine loop, `--bench` throughput mode
- `cpp/Makefile` — `make`/`run`/`bench`/`check`/`clean`
- **Verified**: C++ output is byte-identical to `tests/golden_output.txt`

**Verilog RTL (Stage 4)**
- `rtl/bame_arb_cmp.v` — pure combinational 3-level priority comparator
- `rtl/bame_top.v` — complete synthesisable FSM + datapath (Verilog-2001)
  - One-hot 8-state FSM: IDLE/LOAD/SORT_BUY/SORT_SELL/MATCH/WRITEBACK/OUTPUT/DONE
  - Sequential bubble sort: 49 fixed cycles per side (7 passes × 7 idx)
  - Two-pointer greedy match: one pair evaluated per cycle
  - Non-blocking simultaneous register swap
  - Range-guarded array indexing (no out-of-bounds)
- `rtl/bame_zedboard.xdc` — 100 MHz timing constraints for xc7z020

**Testbench (Stage 5)**
- `rtl/bame_top.v` — added `flush_in` port for partial batch processing
- `rtl/tb_bame_top.v` — 5 test cases, VCD dump, 7 tasks, 497-line Verilog-2001
  - T1: 8 mixed orders → 5 trades (matches golden output)
  - T2: 3 orders + flush → 1 trade (RTL-standalone, no resting book)
  - T3: All-BUY batch → 0 trades
  - T4: Perfect-match batch → 1 trade, 0 residuals
  - T5: Output backpressure stall + correct resume
- `rtl/sim_bame.tcl` — Vivado simulation launch + waveform group setup

**Synthesis & Documentation (Stage 6)**
- `rtl/synth_bame.tcl` — 6-step Vivado batch flow: synth→opt→place→route→reports→bitstream
- `Makefile` (root) — unified 12-target build system (rust/cpp/rtl-sim/rtl-synth/clean)
- `README.md` — comprehensive research documentation (9 sections)
- `results/.gitkeep` — placeholder for generated synthesis artefacts

**Repository Organisation (this release)**
- `.gitignore` — comprehensive coverage: Rust, C++, Vivado, simulation, OS, editors
- `LICENSE` — MIT
- `CITATION.cff` — GitHub citation button support
- `CONTRIBUTING.md` — style guide, test-vector workflow, PR process
- `CHANGELOG.md` — this file
- `.github/workflows/ci.yml` — 4-job CI: C++ verify, Rust build, RTL syntax+sim, structure check
- `.github/ISSUE_TEMPLATE/bug_report.yml` — structured bug report template
- `.github/ISSUE_TEMPLATE/feature_request.yml` — structured feature request template
- `.github/PULL_REQUEST_TEMPLATE.md` — merge checklist
- `paper/bame_technical_report.md` — full technical report with references

### Fixed
- Removed stray `src/actual_output.txt` and `tests/cpp_output.txt`

---

[Unreleased]: https://github.com/aknoru/rx-matching-engine/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/aknoru/rx-matching-engine/releases/tag/v1.0.0

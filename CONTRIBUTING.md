# Contributing to BAME

Thank you for considering a contribution! This document explains how to submit
changes across the **Rust**, **C++**, and **Verilog RTL** layers of the project.

---

## Ground Rules

1. **Determinism is sacred.** All three implementations must produce identical
   output for any given input. A PR that changes the output of one implementation
   but not the others will not be merged without updating the remaining two.

2. **Golden file is the single source of truth.** If you believe the golden output
   is wrong, open an issue first and discuss before changing it.

3. **No external dependencies** (C++ in particular remains stdlib-only).

4. **RTL must remain Verilog-2001 compatible.** No SystemVerilog constructs.

5. **HLS rules** (if adding HLS artefacts): no dynamic allocation, no STL, no TCL.

---

## Development Setup

### C++
```bash
# Build
cd cpp && make

# Verify against golden output
make check
```

### Rust
```bash
cargo build --release
cargo run --release -- tests/orders.txt
```

### Verilog (syntax check — requires iverilog)
```bash
iverilog -g2001 -Wall -t null rtl/bame_arb_cmp.v rtl/bame_top.v
iverilog -g2001 -Wall -t null rtl/bame_arb_cmp.v rtl/bame_top.v rtl/tb_bame_top.v
```

### Verilog (simulation — requires Vivado or iverilog + vvp)
```bash
# With iverilog:
iverilog -g2001 -o /tmp/bame_sim rtl/bame_arb_cmp.v rtl/bame_top.v rtl/tb_bame_top.v
vvp /tmp/bame_sim

# With Vivado:
vivado -mode batch -source rtl/sim_bame.tcl
```

---

## Adding New Test Vectors

1. Append orders to `tests/orders.txt` (CSV format, monotonically increasing timestamp).
2. Update `tests/orders.mem` — generate 145-bit binary entries matching the encoding in `rtl/bame_top.v` (see §3.1 of the README).
3. Run the **C++ engine** (as the reference after Rust) to regenerate `tests/golden_output.txt`:
   ```bash
   cd cpp && ./engine ../tests/orders.txt > ../tests/golden_output.txt
   ```
4. Manually inspect the output and verify the trades are correct.
5. Update the testbench `rtl/tb_bame_top.v` if your new vectors require new test cases.

---

## Submitting a Pull Request

1. Fork the repository and create a branch: `git checkout -b feat/my-improvement`
2. Make your changes, following the checklist in `.github/PULL_REQUEST_TEMPLATE.md`.
3. Ensure all CI jobs pass locally before opening the PR.
4. Keep commits atomic and write clear commit messages:
   ```
   feat(rtl): add early-exit optimisation to bubble sort
   
   Skip remaining comparisons in a sort pass when no swap occurred.
   Reduces average sort cycles from 49 to ~12 for typical inputs.
   ```
5. Open the PR and fill in the template completely.

---

## Code Style

### Rust
- Follow `rustfmt` defaults (`cargo fmt`)
- Keep `clippy` warnings at zero (`cargo clippy -- -D warnings`)

### C++
- 4-space indent, K&R brace style
- `clang-format` with Google style is acceptable but not enforced
- No `using namespace std;`

### Verilog
- 4-space indent
- **All** registers declared and driven from a single `always @(posedge clk)` block with synchronous high reset (`if (rst)`)
- **Non-blocking assignments only** in clocked blocks
- `begin`/`end` required on all multi-statement branches
- Comment every FSM state transition

---

## Reporting Security Issues

Do not open a public GitHub issue for security vulnerabilities. Email the
maintainers directly. (This is a research project with no production deployment,
but good practice is maintained.)

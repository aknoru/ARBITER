## Pull Request

### Summary
<!-- One paragraph describing what this PR does and why. -->

### Type of Change
<!-- Check all that apply -->
- [ ] Bug fix (non-breaking; fixes an issue)
- [ ] New feature (non-breaking; adds functionality)
- [ ] Breaking change (changes an interface or output format)
- [ ] Documentation update
- [ ] Performance improvement
- [ ] Refactoring (no behavioral change)

### Affected Components
- [ ] Rust reference (`src/`)
- [ ] C++ benchmark (`cpp/`)
- [ ] Verilog RTL (`rtl/bame_top.v`, `rtl/bame_arb_cmp.v`)
- [ ] Testbench (`rtl/tb_bame_top.v`)
- [ ] Build system (`Makefile`, `cpp/Makefile`)
- [ ] Documentation (`README.md`, `paper/`)
- [ ] Tests / golden output (`tests/`)

### Verification Checklist
<!-- All boxes must be checked before merging -->
- [ ] `make cpp-build` succeeds with zero warnings
- [ ] `make cpp-check` passes (output matches `tests/golden_output.txt`)
- [ ] `make rust-build` succeeds
- [ ] Verilog files pass `iverilog -g2001 -Wall` syntax check
- [ ] If RTL changed: all 5 testbench cases still pass
- [ ] If output format changed: `tests/golden_output.txt` updated accordingly
- [ ] If new test vectors added: `tests/orders.mem` updated to match
- [ ] `CHANGELOG.md` updated with a summary of this change

### Notes for Reviewer
<!-- Anything else the reviewer should know: design decisions, tradeoffs, known limitations. -->

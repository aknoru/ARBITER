# ============================================================
# Batched Arbitration Matching Engine — C++ Build System
# ============================================================
#
# Targets:
#   make           Build the engine executable (default)
#   make run       Run against the canonical test input
#   make bench     Run with --bench flag (throughput report to stderr)
#   make check     Compare output with golden_output.txt
#   make clean     Remove build artifacts
#
# Requirements:
#   g++ with C++17 support (GCC 7+ or Clang 5+)
#   No external dependencies

CXX      := g++
CXXFLAGS := -std=c++17 -O2 -Wall -Wextra -pedantic
TARGET   := engine

SRCS     := main.cpp orderbook.cpp matcher.cpp
OBJS     := $(SRCS:.cpp=.o)

# Path to the shared test vectors (relative to cpp/)
ORDERS   := ../tests/orders.txt
GOLDEN   := ../tests/golden_output.txt

# ---- Default target ---------------------------------------------------------
.PHONY: all
all: $(TARGET)

# ---- Link -------------------------------------------------------------------
$(TARGET): $(OBJS)
	$(CXX) $(CXXFLAGS) -o $@ $^
	@echo "Built: $(TARGET)"

# ---- Compile (pattern rule) -------------------------------------------------
%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c -o $@ $<

# ---- Run targets ------------------------------------------------------------
.PHONY: run
run: $(TARGET)
	./$(TARGET) $(ORDERS)

.PHONY: bench
bench: $(TARGET)
	./$(TARGET) $(ORDERS) --bench

# ---- Correctness check ------------------------------------------------------
# Compares actual output against the pre-computed golden file.
# Exits 0 on match; prints diff on mismatch.
.PHONY: check
check: $(TARGET)
	@echo "Running engine and comparing with golden output..."
	@./$(TARGET) $(ORDERS) > /tmp/actual_output.txt 2>/dev/null
	@if diff -q $(GOLDEN) /tmp/actual_output.txt > /dev/null 2>&1; then \
	    echo "PASS: output matches golden_output.txt"; \
	else \
	    echo "FAIL: output differs from golden_output.txt"; \
	    diff $(GOLDEN) /tmp/actual_output.txt; \
	    exit 1; \
	fi

# ---- Clean ------------------------------------------------------------------
.PHONY: clean
clean:
	rm -f $(OBJS) $(TARGET) /tmp/actual_output.txt
	@echo "Cleaned."

# ---- Help -------------------------------------------------------------------
.PHONY: help
help:
	@echo ""
	@echo "  make          Build the engine"
	@echo "  make run      Run: ./engine ../tests/orders.txt"
	@echo "  make bench    Run with throughput metrics"
	@echo "  make check    Verify output matches golden_output.txt"
	@echo "  make clean    Remove build artifacts"
	@echo ""

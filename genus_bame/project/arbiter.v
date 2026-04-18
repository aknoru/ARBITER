// =============================================================================
// arbiter.v  - BAME Arbitration Comparator
// =============================================================================
// Pure combinational module; no registers, no latches.
// Implements the canonical three-level arbitration key:
//   BUY  sort: higher price -> lower timestamp -> lower order_id
//   SELL sort: lower  price -> lower timestamp -> lower order_id
// =============================================================================

`timescale 1ns / 1ps

module arbiter (
    // ---- Order A fields ----
    input  wire [31:0] ts_a,     // timestamp
    input  wire [63:0] id_a,     // order_id (unique, final tie-breaker)
    input  wire [15:0] price_a,  // price tick

    // ---- Order B fields ----
    input  wire [31:0] ts_b,
    input  wire [63:0] id_b,
    input  wire [15:0] price_b,

    // ---- Sort direction ----
    input  wire        sort_buy, // 1 = BUY sort (price DESC), 0 = SELL sort (price ASC)

    // ---- Output ----
    output wire        a_before_b // 1 = order A has strictly higher priority than order B
);

// ---------------------------------------------------------------------------
// Level-1: price comparison
// ---------------------------------------------------------------------------
wire price_eq  = (price_a == price_b);
wire price_gt  = (price_a >  price_b);
wire price_lt  = (price_a <  price_b);

// ---------------------------------------------------------------------------
// Level-2: timestamp comparison
// ---------------------------------------------------------------------------
wire ts_eq  = (ts_a == ts_b);
wire ts_lt  = (ts_a <  ts_b);

// ---------------------------------------------------------------------------
// Level-3: order_id tie-breaker
// ---------------------------------------------------------------------------
wire id_lt = (id_a < id_b);

// ---------------------------------------------------------------------------
// Combine into priority decision
// ---------------------------------------------------------------------------
wire buy_priority  = price_gt
                   | (price_eq & ts_lt)
                   | (price_eq & ts_eq & id_lt);

wire sell_priority = price_lt
                   | (price_eq & ts_lt)
                   | (price_eq & ts_eq & id_lt);

assign a_before_b = sort_buy ? buy_priority : sell_priority;

endmodule

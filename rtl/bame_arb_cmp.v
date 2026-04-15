// =============================================================================
// bame_arb_cmp.v  —  Arbitration Comparator
// =============================================================================
// Pure combinational module; no registers, no latches.
// Used by bame_top.v during SORT_BUY and SORT_SELL states.
//
// Implements the canonical three-level arbitration key (Spec §6):
//   BUY  sort: higher price → lower timestamp → lower order_id
//   SELL sort: lower  price → lower timestamp → lower order_id
//
// Target: xc7z020 (ZedBoard), 100 MHz clock domain
// =============================================================================

`timescale 1ns / 1ps

module bame_arb_cmp (
    // ---- Order A fields ----
    input  wire [31:0] ts_a,     // timestamp
    input  wire [31:0] id_a,     // order_id (unique, final tie-breaker)
    input  wire [15:0] price_a,  // price tick

    // ---- Order B fields ----
    input  wire [31:0] ts_b,
    input  wire [31:0] id_b,
    input  wire [15:0] price_b,

    // ---- Sort direction ----
    input  wire        sort_buy, // 1 = BUY sort (price DESC), 0 = SELL sort (price ASC)

    // ---- Output ----
    output wire        a_before_b // 1 = order A has strictly higher priority than order B
                                  // 0 = order B has equal or higher priority (swap needed)
);

// ---------------------------------------------------------------------------
// Level-1: price comparison
// ---------------------------------------------------------------------------
wire price_eq  = (price_a == price_b);
wire price_gt  = (price_a >  price_b);  // A has higher price
wire price_lt  = (price_a <  price_b);  // A has lower  price

// ---------------------------------------------------------------------------
// Level-2: timestamp comparison (lower = earlier = higher priority)
// ---------------------------------------------------------------------------
wire ts_eq  = (ts_a == ts_b);
wire ts_lt  = (ts_a <  ts_b);           // A arrived earlier

// ---------------------------------------------------------------------------
// Level-3: order_id tie-breaker (lower id = higher priority)
// ---------------------------------------------------------------------------
wire id_lt = (id_a < id_b);

// ---------------------------------------------------------------------------
// Combine into priority decision
// ---------------------------------------------------------------------------
// For BUY sort:  A before B if A.price > B.price
//                              OR  (equal price AND A.ts < B.ts)
//                              OR  (equal price AND equal ts AND A.id < B.id)
wire buy_priority  = price_gt
                   | (price_eq & ts_lt)
                   | (price_eq & ts_eq & id_lt);

// For SELL sort: A before B if A.price < B.price  (reversed price comparison)
//               rest of levels identical
wire sell_priority = price_lt
                   | (price_eq & ts_lt)
                   | (price_eq & ts_eq & id_lt);

assign a_before_b = sort_buy ? buy_priority : sell_priority;

// Synthesis note:
//   This module infers ~10 LUTs on xc7z020 (three parallel comparators + final mux).
//   All paths are purely combinational; critical path is bounded by two 32-bit
//   magnitude comparators (ts, id) in parallel.

endmodule

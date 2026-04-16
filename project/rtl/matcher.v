// =============================================================================
// matcher.v  - BAME Combinational Match Logic
// =============================================================================
// Evaluates the current buy and sell pointers to determine if a match exists.
// Purely combinatorial.
//
`timescale 1ns / 1ps

module matcher (
    input  wire [15:0] m_buy_price,
    input  wire [15:0] m_sell_price,
    input  wire [31:0] m_buy_qty,
    input  wire [31:0] m_sell_qty,
    input  wire [3:0]  buy_ptr,
    input  wire [3:0]  sell_ptr,
    input  wire [3:0]  buy_cnt,
    input  wire [3:0]  sell_cnt,

    output wire        match_cond,
    output wire [31:0] trade_qty,
    output wire [15:0] trade_price,
    output wire        ptrs_valid
);

    assign match_cond  = (m_buy_price >= m_sell_price);
    assign trade_qty   = (m_buy_qty < m_sell_qty) ? m_buy_qty : m_sell_qty;
    assign trade_price = m_sell_price;
    assign ptrs_valid  = (buy_ptr < buy_cnt) && (sell_ptr < sell_cnt);

endmodule

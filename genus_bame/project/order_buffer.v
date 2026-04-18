// =============================================================================
// order_buffer.v  - BAME Sequential Buffer Array
// =============================================================================
// Pure combinatorial/structural wrapper for register loading to satisfy ASIC
// directory structure without redesigning the core state machine.
//
`timescale 1ns / 1ps

module order_buffer #(
    parameter integer BATCH_SIZE = 8
)(
    input  wire         clk,
    input  wire         rst,
    
    // Write Interface from Load State
    input  wire         load_en,
    input  wire [144:0] order_in,
    input  wire         is_buy,
    input  wire [3:0]   load_idx,
    
    // Output Interfaces for Sort/Match would normally go here.
    // However, to keep "No redesign logic" strictly true, the actual
    // D-FFs must remain in top.v so the identical non-blocking assignments
    // for sorting and matching do not infer structural latches across boundaries.
    
    // Instead, this module acts as a combinatorial router for the load stage.
    output wire [144:0] route_to_buy_buf,
    output wire [144:0] route_to_sell_buf,
    output wire         buy_we,
    output wire         sell_we
);

    assign buy_we            = load_en & is_buy;
    assign sell_we           = load_en & !is_buy;
    assign route_to_buy_buf  = order_in;
    assign route_to_sell_buf = order_in;

endmodule

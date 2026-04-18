// =============================================================================
// sort_unit.v  - BAME Combinational Sort Logic
// =============================================================================
// Provides bounds-checking and swap decision logic to the master FSM.
// Purely combinatorial.
//
`timescale 1ns / 1ps

module sort_unit (
    input  wire [3:0] active_cnt,
    input  wire [2:0] sort_idx,
    input  wire       sort_a_before_b,
    
    output wire       sort_in_range,
    output wire       do_swap
);

    wire       sort_has_pairs = (active_cnt >= 4'd2);
    wire [3:0] sort_max_idx   = active_cnt - 4'd2;
    
    assign sort_in_range = sort_has_pairs && ({1'b0, sort_idx} <= sort_max_idx);
    assign do_swap       = sort_in_range && !sort_a_before_b;

endmodule

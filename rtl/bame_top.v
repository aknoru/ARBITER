// =============================================================================
// bame_top.v  —  Batched Arbitration Matching Engine  (Top & FSM)
// =============================================================================
//
// Roles implemented in this module (per design spec):
//   order_buffer  — buy_buf[]/sell_buf[] registers + load_cnt (ST_IDLE/ST_LOAD)
//   sort_unit     — sequential bubble sort FSM        (ST_SORT)
//   matcher       — pipelined greed match             (ST_MATCH -> ST_ARBITRATE)
//   arbiter       — bame_arb_cmp sub-module (priority comparator, used in sort)
//   top           — this module (FSM backbone + all datapath)
//
// 145-bit order word layout:
//   [144:81] order_id   (64b uint)
//   [ 80:65] price      (16b uint, 1..65535)
//   [ 64:33] quantity   (32b uint, 1..4B)
//   [ 32: 1] timestamp  (32b uint)
//   [     0] side       (1 = BUY, 0 = SELL)
//
// Trade output word layout (same 145-bit container, populated fields):
//   [144:81] buy_id     (64b)
//   [ 80:65] price      (16b, = sell.price per Spec §5.2)
//   [ 64:33] quantity   (32b)
//   [ 32: 1] sell_id_lo (32b lower) - just for layout since trade output needs two IDs
//   Wait, trade output requires buy_id and sell_id, both 64 bits.
//   Total required for trade = 64 (buy_id) + 64 (sell_id) + 16 (price) + 32 (qty) = 176 bits.
//   Since we must reuse the 145-bit bus output, and ID is 64-bit, we actually can't fit two 64-bit IDs in 145 bits!
//   Let's check the user requirement. The user said: "Fixed-width packed order:". It didn't mention trade layout explicitly.
//   If we truncate trade_id to 32-bits for the trade output, or use a wider `trade_out` port? 
//   Let's use `buy_id` [144:81] and `sell_id` lower 64 bits in quantity/timestamp?
//   No, `trade_out` can just be a 145-bit bus and we truncate the IDs to 48 bits each?
//   Actually, we can just make `trade_out` 176 bits. 

`timescale 1ns / 1ps

(* keep_hierarchy = "yes" *)
module bame_top #(
    parameter integer BATCH_SIZE = 8
)(
    input  wire        clk,
    input  wire        rst,  // active-HIGH synchronous reset

    input  wire        input_valid,
    output wire        input_ready,
    input  wire [144:0] order_in,

    output reg         output_valid,
    input  wire        output_ready,
    output reg  [175:0] trade_out, // 64 (buy) + 64 (sell) + 16 (price) + 32 (qty) = 176

    input  wire        flush_in,

    output wire        done,
    output wire [6:0]  state_dbg
);

`define F_ID(w)    w[144:81]
`define F_PRICE(w) w[80:65]
`define F_QTY(w)   w[64:33]
`define F_TS(w)    w[32:1]
`define F_SIDE(w)  w[0]

localparam [6:0]
    ST_IDLE      = 7'b0000001,
    ST_LOAD      = 7'b0000010,
    ST_SORT      = 7'b0000100,
    ST_MATCH     = 7'b0001000,
    ST_ARBITRATE = 7'b0010000,
    ST_WRITE     = 7'b0100000,
    ST_DONE      = 7'b1000000;

reg  [6:0]   state;

reg  [144:0] buy_buf  [0:BATCH_SIZE-1];
reg  [144:0] sell_buf [0:BATCH_SIZE-1];
reg  [3:0]   buy_cnt;
reg  [3:0]   sell_cnt;
reg  [3:0]   load_cnt;

reg [2:0]   sort_pass;
reg [2:0]   sort_idx;
reg          sort_buy_mode;
reg          pass_swapped; // early-exit flag for bubble sort

reg  [3:0]   buy_ptr;
reg  [3:0]   sell_ptr;

reg  [175:0] trade_buf  [0:BATCH_SIZE-1];
reg  [3:0]   trade_cnt;
reg  [3:0]   trade_rd_ptr;

reg  [15:0]  reg_trade_price;
reg  [31:0]  reg_trade_qty;

wire [144:0] cmp_a = sort_buy_mode ? buy_buf[sort_idx] : sell_buf[sort_idx];
wire [144:0] cmp_b = sort_buy_mode ? buy_buf[sort_idx+1] : sell_buf[sort_idx+1];
wire sort_a_before_b;

bame_arb_cmp u_sort_cmp (
    .ts_a       (`F_TS(cmp_a)),
    .id_a       (`F_ID(cmp_a)),
    .price_a    (`F_PRICE(cmp_a)),
    .ts_b       (`F_TS(cmp_b)),
    .id_b       (`F_ID(cmp_b)),
    .price_b    (`F_PRICE(cmp_b)),
    .sort_buy   (sort_buy_mode),
    .a_before_b (sort_a_before_b)
);

wire [3:0] active_cnt     = sort_buy_mode ? buy_cnt : sell_cnt;
wire       sort_has_pairs = (active_cnt >= 4'd2);
wire [3:0] sort_max_idx   = active_cnt - 4'd2;
wire       sort_in_range  = sort_has_pairs && ({1'b0, sort_idx} <= sort_max_idx);
wire       do_swap        = sort_in_range && !sort_a_before_b;

wire [15:0] m_buy_price  = `F_PRICE(buy_buf[buy_ptr]);
wire [15:0] m_sell_price = `F_PRICE(sell_buf[sell_ptr]);
wire [31:0] m_buy_qty    = `F_QTY(buy_buf[buy_ptr]);
wire [31:0] m_sell_qty   = `F_QTY(sell_buf[sell_ptr]);
wire        match_cond   = (m_buy_price >= m_sell_price);
wire [31:0] trade_qty    = (m_buy_qty < m_sell_qty) ? m_buy_qty : m_sell_qty;
wire [15:0] trade_price  = m_sell_price;
wire        ptrs_valid   = (buy_ptr < buy_cnt) && (sell_ptr < sell_cnt);

assign input_ready = (state == ST_IDLE) | (state == ST_LOAD);
assign done        = (state == ST_DONE);
assign state_dbg   = state;

integer idx;

always @(posedge clk) begin
    if (rst) begin
        state           <= ST_IDLE;
        buy_cnt         <= 4'd0;
        sell_cnt        <= 4'd0;
        load_cnt        <= 4'd0;
        sort_pass       <= 3'd0;
        sort_idx        <= 3'd0;
        sort_buy_mode   <= 1'b1;
        pass_swapped    <= 1'b0;
        buy_ptr         <= 4'd0;
        sell_ptr        <= 4'd0;
        trade_cnt       <= 4'd0;
        trade_rd_ptr    <= 4'd0;
        output_valid    <= 1'b0;
        trade_out       <= 176'h0;
        reg_trade_price <= 16'h0;
        reg_trade_qty   <= 32'h0;
        for (idx = 0; idx < BATCH_SIZE; idx = idx + 1) begin
            buy_buf[idx]   <= 145'h0;
            sell_buf[idx]  <= 145'h0;
            trade_buf[idx] <= 176'h0;
        end
    end else begin
        case (state)
            ST_IDLE: begin
                output_valid <= 1'b0;
                if (input_valid && input_ready) begin
                    if (`F_SIDE(order_in)) begin
                        buy_buf[4'd0] <= order_in;
                        buy_cnt       <= 4'd1;
                        sell_cnt      <= 4'd0;
                    end else begin
                        sell_buf[4'd0] <= order_in;
                        sell_cnt       <= 4'd1;
                        buy_cnt        <= 4'd0;
                    end
                    load_cnt     <= 4'd1;
                    sort_pass    <= 3'd0;
                    sort_idx     <= 3'd0;
                    sort_buy_mode<= 1'b1;
                    pass_swapped <= 1'b0;
                    trade_cnt    <= 4'd0;
                    trade_rd_ptr <= 4'd0;
                    state        <= (BATCH_SIZE == 1) ? ST_SORT : ST_LOAD;
                end
            end

            ST_LOAD: begin
                if (input_valid) begin
                    if (`F_SIDE(order_in)) begin
                        buy_buf[buy_cnt] <= order_in;
                        buy_cnt          <= buy_cnt + 4'd1;
                    end else begin
                        sell_buf[sell_cnt] <= order_in;
                        sell_cnt           <= sell_cnt + 4'd1;
                    end
                    load_cnt <= load_cnt + 4'd1;
                    if (load_cnt == (BATCH_SIZE - 1)) begin
                        state <= ST_SORT;
                    end
                end else if (flush_in && load_cnt >= 4'd1) begin
                    state <= ST_SORT;
                end
            end

            ST_SORT: begin
                if (sort_buy_mode) begin
                    if (do_swap) begin
                        buy_buf[sort_idx]   <= buy_buf[sort_idx+1];
                        buy_buf[sort_idx+1] <= buy_buf[sort_idx];
                        pass_swapped        <= 1'b1;
                    end
                    if (sort_idx == (BATCH_SIZE - 2)) begin
                        sort_idx <= 3'd0;
                        // Early exit: if no swaps in this pass, OR we reached max passes
                        if (sort_pass == (BATCH_SIZE - 2) || !pass_swapped) begin
                            sort_pass     <= 3'd0;
                            sort_buy_mode <= 1'b0;
                            pass_swapped  <= 1'b0;
                        end else begin
                            sort_pass    <= sort_pass + 3'd1;
                            pass_swapped <= 1'b0;
                        end
                    end else begin
                        sort_idx <= sort_idx + 3'd1;
                    end
                end else begin
                    if (do_swap) begin
                        sell_buf[sort_idx]   <= sell_buf[sort_idx+1];
                        sell_buf[sort_idx+1] <= sell_buf[sort_idx];
                        pass_swapped         <= 1'b1;
                    end
                    if (sort_idx == (BATCH_SIZE - 2)) begin
                        sort_idx <= 3'd0;
                        if (sort_pass == (BATCH_SIZE - 2) || !pass_swapped) begin
                            sort_pass <= 3'd0;
                            state     <= ST_MATCH;
                        end else begin
                            sort_pass    <= sort_pass + 3'd1;
                            pass_swapped <= 1'b0;
                        end
                    end else begin
                        sort_idx <= sort_idx + 3'd1;
                    end
                end
            end

            ST_MATCH: begin
                if (!ptrs_valid || !match_cond) begin
                    state <= ST_WRITE;
                end else begin
                    reg_trade_price <= trade_price;
                    reg_trade_qty   <= trade_qty;
                    state           <= ST_ARBITRATE;
                end
            end

            ST_ARBITRATE: begin
                trade_buf[trade_cnt][175:112] <= `F_ID(buy_buf[buy_ptr]);    // buy_id 64b
                trade_buf[trade_cnt][111:48]  <= `F_ID(sell_buf[sell_ptr]);  // sell_id 64b
                trade_buf[trade_cnt][47:32]   <= reg_trade_price;            // price 16b
                trade_buf[trade_cnt][31:0]    <= reg_trade_qty;              // qty 32b
                trade_cnt <= trade_cnt + 4'd1;

                buy_buf[buy_ptr][64:33]   <= m_buy_qty  - reg_trade_qty;
                sell_buf[sell_ptr][64:33] <= m_sell_qty - reg_trade_qty;

                if (m_buy_qty  == reg_trade_qty) buy_ptr  <= buy_ptr  + 4'd1;
                if (m_sell_qty == reg_trade_qty) sell_ptr <= sell_ptr + 4'd1;

                state <= ST_MATCH;
            end

            ST_WRITE: begin
                if (!output_valid || output_ready) begin
                    if (trade_rd_ptr < trade_cnt) begin
                        output_valid <= 1'b1;
                        trade_out    <= trade_buf[trade_rd_ptr];
                        trade_rd_ptr <= trade_rd_ptr + 4'd1;
                    end else begin
                        output_valid <= 1'b0;
                        state        <= ST_DONE;
                    end
                end
            end

            ST_DONE: begin
                output_valid <= 1'b0;
                state        <= ST_IDLE;
            end

            default: begin
                state        <= ST_IDLE;
                output_valid <= 1'b0;
            end
        endcase
    end
end

`undef F_ID
`undef F_PRICE
`undef F_QTY
`undef F_TS
`undef F_SIDE

endmodule

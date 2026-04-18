// =============================================================================
// top.v  - BAME Top Level (ASIC Cleaned)
// =============================================================================
// Stripped of FPGA attributes. Structured to instantiate the physical
// combinatorial submodules required for the strict ASIC flow without
// creating sequential loops or altering the cycle-exact algorithm.
//
`timescale 1ns / 1ps

module top #(
    parameter integer BATCH_SIZE = 8
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        input_valid,
    output wire        input_ready,
    input  wire [144:0] order_in,

    output reg         output_valid,
    input  wire        output_ready,
    output reg  [175:0] trade_out,

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
reg          pass_swapped;

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

arbiter u_arbiter (
    .ts_a       (`F_TS(cmp_a)),
    .id_a       (`F_ID(cmp_a)),
    .price_a    (`F_PRICE(cmp_a)),
    .ts_b       (`F_TS(cmp_b)),
    .id_b       (`F_ID(cmp_b)),
    .price_b    (`F_PRICE(cmp_b)),
    .sort_buy   (sort_buy_mode),
    .a_before_b (sort_a_before_b)
);

wire [3:0] active_cnt = sort_buy_mode ? buy_cnt : sell_cnt;
wire       sort_in_range;
wire       do_swap;

sort_unit u_sort_unit (
    .active_cnt      (active_cnt),
    .sort_idx        (sort_idx),
    .sort_a_before_b (sort_a_before_b),
    .sort_in_range   (sort_in_range),
    .do_swap         (do_swap)
);

wire [15:0] m_buy_price  = `F_PRICE(buy_buf[buy_ptr]);
wire [15:0] m_sell_price = `F_PRICE(sell_buf[sell_ptr]);
wire [31:0] m_buy_qty    = `F_QTY(buy_buf[buy_ptr]);
wire [31:0] m_sell_qty   = `F_QTY(sell_buf[sell_ptr]);
wire        match_cond;
wire [31:0] trade_qty;
wire [15:0] trade_price;
wire        ptrs_valid;

matcher u_matcher (
    .m_buy_price  (m_buy_price),
    .m_sell_price (m_sell_price),
    .m_buy_qty    (m_buy_qty),
    .m_sell_qty   (m_sell_qty),
    .buy_ptr      (buy_ptr),
    .sell_ptr     (sell_ptr),
    .buy_cnt      (buy_cnt),
    .sell_cnt     (sell_cnt),
    .match_cond   (match_cond),
    .trade_qty    (trade_qty),
    .trade_price  (trade_price),
    .ptrs_valid   (ptrs_valid)
);

wire [144:0] route_to_buy_buf;
wire [144:0] route_to_sell_buf;
wire buy_we, sell_we;

order_buffer u_order_buffer (
    .clk              (clk),
    .rst              (rst),
    .load_en          ((state == ST_IDLE && input_valid && input_ready) || (state == ST_LOAD && input_valid)),
    .order_in         (order_in),
    .is_buy           (`F_SIDE(order_in)),
    .load_idx         ((state == ST_IDLE) ? 4'd0 : (`F_SIDE(order_in) ? buy_cnt : sell_cnt)),
    .route_to_buy_buf (route_to_buy_buf),
    .route_to_sell_buf(route_to_sell_buf),
    .buy_we           (buy_we),
    .sell_we          (sell_we)
);


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
                    if (buy_we) begin
                        buy_buf[4'd0] <= route_to_buy_buf;
                        buy_cnt       <= 4'd1;
                        sell_cnt      <= 4'd0;
                    end else if (sell_we) begin
                        sell_buf[4'd0] <= route_to_sell_buf;
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
                    if (buy_we) begin
                        buy_buf[buy_cnt] <= route_to_buy_buf;
                        buy_cnt          <= buy_cnt + 4'd1;
                    end else if (sell_we) begin
                        sell_buf[sell_cnt] <= route_to_sell_buf;
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
                trade_buf[trade_cnt][175:112] <= `F_ID(buy_buf[buy_ptr]);    // buy_id
                trade_buf[trade_cnt][111:48]  <= `F_ID(sell_buf[sell_ptr]);  // sell_id
                trade_buf[trade_cnt][47:32]   <= reg_trade_price;            // price
                trade_buf[trade_cnt][31:0]    <= reg_trade_qty;              // qty
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

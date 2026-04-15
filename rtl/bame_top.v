// =============================================================================
// bame_top.v  —  Batched Arbitration Matching Engine  (Top & FSM)
// =============================================================================
//
// Roles implemented in this module (per design spec):
//   order_buffer  — buy_buf[]/sell_buf[] registers + load_cnt (ST_IDLE/ST_LOAD)
//   sort_unit     — sequential bubble sort FSM        (ST_SORT_BUY/ST_SORT_SELL)
//   matcher       — two-pointer greedy match          (ST_MATCH)
//   arbiter       — bame_arb_cmp sub-module (priority comparator, used in sort)
//   top           — this module (FSM backbone + all datapath)
//
// 128-bit order word layout:
//   [127:96] timestamp  (32b uint)
//   [ 95:64] order_id   (32b uint)
//   [    63] side        (1 = BUY, 0 = SELL)
//   [ 62:48] reserved
//   [ 47:32] price       (16b uint, 1..65535)
//   [ 31:16] quantity    (16b uint, 1..65535)
//   [ 15: 0] reserved
//
// Trade output word layout (same 128-bit container, top 96 bits used):
//   [127:96] buy_id   (32b)
//   [ 95:64] sell_id  (32b)
//   [ 63:48] reserved
//   [ 47:32] price    (16b, = sell.price per Spec §5.2)
//   [ 31:16] quantity (16b)
//   [ 15: 0] reserved
//
// FSM state encoding: one-hot (8 states → 8-bit register).
//
// Synthesis target: Xilinx xc7z020 (ZedBoard), 100 MHz single clock.
//
// Design safety rules enforced:
//   ✓ Single clock domain
//   ✓ No latches  (all state in posedge clk registers with async reset)
//   ✓ No combinational loops
//   ✓ No blocking delays in always blocks
//   ✓ Fixed-size arrays (BATCH_SIZE = 8, parameterised)
//   ✓ All outputs registered
//   ✓ Guarded array indices (sort_idx never exceeds BATCH_SIZE-2)
// =============================================================================

`timescale 1ns / 1ps

module bame_top #(
    parameter integer BATCH_SIZE = 8  // must be a power-of-2, 2..8
)(
    // ---- Clock and reset ----
    input  wire        clk,
    input  wire        rst_n,  // active-low asynchronous reset

    // ---- Input order stream (one order per cycle, handshake) ----
    input  wire        input_valid,
    output wire        input_ready,   // 1 when engine accepts orders (IDLE or LOAD)
    input  wire [127:0] order_in,

    // ---- Trade output stream (one trade per cycle, handshake) ----
    output reg         output_valid,
    input  wire        output_ready,
    output reg  [127:0] trade_out,

    // ---- Flush control ----
    // Assert flush_in for ≥1 cycle while in ST_LOAD to force a partial batch
    // through the pipeline without waiting for BATCH_SIZE orders.
    // Ignored in ST_IDLE (no orders loaded yet) and all non-LOAD states.
    // When both input_valid and flush_in are asserted simultaneously,
    // the incoming order is accepted first (flush takes effect next cycle).
    input  wire        flush_in,

    // ---- Status ----
    output wire        done,       // high for one cycle when batch is fully processed
    output wire [7:0]  state_dbg  // raw FSM state register for waveform debugging
);

// =============================================================================
// Field extraction (macros for 128-bit order word)
// =============================================================================
`define F_TS(w)    w[127:96]
`define F_ID(w)    w[95:64]
`define F_SIDE(w)  w[63]
`define F_PRICE(w) w[47:32]
`define F_QTY(w)   w[31:16]

// =============================================================================
// FSM State encoding — one-hot
// =============================================================================
localparam [7:0]
    ST_IDLE      = 8'b00000001,  // [0] idle, waiting for batch start
    ST_LOAD      = 8'b00000010,  // [1] loading orders into buy/sell buffers
    ST_SORT_BUY  = 8'b00000100,  // [2] bubble-sorting buy_buf
    ST_SORT_SELL = 8'b00001000,  // [3] bubble-sorting sell_buf
    ST_MATCH     = 8'b00010000,  // [4] two-pointer matching + arbitration
    ST_WRITEBACK = 8'b00100000,  // [5] residuals committed; setup output
    ST_OUTPUT    = 8'b01000000,  // [6] streaming trade records out
    ST_DONE      = 8'b10000000;  // [7] done pulse, return to IDLE

// =============================================================================
// Datapath registers
// =============================================================================

reg  [7:0]   state;

// -- Order storage buffers -- (BATCH_SIZE entries, 128 bits each)
reg  [127:0] buy_buf  [0:BATCH_SIZE-1];
reg  [127:0] sell_buf [0:BATCH_SIZE-1];

// -- Counts --
reg  [3:0]   buy_cnt;    // number of BUY orders in buy_buf  (0..BATCH_SIZE)
reg  [3:0]   sell_cnt;   // number of SELL orders in sell_buf (0..BATCH_SIZE)
reg  [3:0]   load_cnt;   // orders loaded this batch          (0..BATCH_SIZE)

// -- Sort control --
reg  [2:0]   sort_pass;  // current pass  (0..BATCH_SIZE-2)
reg  [2:0]   sort_idx;   // current index in pass (0..BATCH_SIZE-2)

// -- Match pointers --
reg  [3:0]   buy_ptr;    // cursor into sorted buy_buf
reg  [3:0]   sell_ptr;   // cursor into sorted sell_buf

// -- Trade output buffer --
reg  [127:0] trade_buf  [0:BATCH_SIZE-1];  // max BATCH_SIZE trades
reg  [3:0]   trade_cnt;     // trades recorded
reg  [3:0]   trade_rd_ptr;  // output read cursor

// =============================================================================
// Arbitration comparator instance (shared by SORT_BUY and SORT_SELL states)
// =============================================================================

// sort_buy_mode: 1 when sorting the BUY side (state bit[2]), 0 for SELL (bit[3])
wire sort_buy_mode = state[2];

// Select which buffer to compare based on current sort state.
// sort_idx is bounded to [0..BATCH_SIZE-2], so sort_idx+1 is always in range.
wire [127:0] cmp_a = sort_buy_mode ? buy_buf [sort_idx    ] : sell_buf[sort_idx    ];
wire [127:0] cmp_b = sort_buy_mode ? buy_buf [sort_idx + 1] : sell_buf[sort_idx + 1];

wire sort_a_before_b;  // 1 = cmp_a has higher priority (no swap needed)

bame_arb_cmp u_sort_cmp (
    .ts_a       (`F_TS   (cmp_a)),
    .id_a       (`F_ID   (cmp_a)),
    .price_a    (`F_PRICE(cmp_a)),
    .ts_b       (`F_TS   (cmp_b)),
    .id_b       (`F_ID   (cmp_b)),
    .price_b    (`F_PRICE(cmp_b)),
    .sort_buy   (sort_buy_mode),
    .a_before_b (sort_a_before_b)
);

// -- Sort range guard: only compare/swap indices within the live count --
// active_cnt is the number of elements in the currently sorted buffer.
wire [3:0] active_cnt = sort_buy_mode ? buy_cnt : sell_cnt;

// sort_idx must be <= active_cnt - 2 to avoid comparing past the last valid entry.
// Guard against underflow when active_cnt < 2 (nothing to sort).
wire       sort_has_pairs  = (active_cnt >= 4'd2);
wire [3:0] sort_max_idx    = active_cnt - 4'd2;   // valid only when sort_has_pairs
wire       sort_in_range   = sort_has_pairs &&
                              ({1'b0, sort_idx} <= sort_max_idx);

// Swap decision: B has higher priority than A → A and B must be swapped
wire do_swap = sort_in_range && !sort_a_before_b;

// =============================================================================
// Match combinational signals (used in ST_MATCH only)
// =============================================================================

wire [15:0] m_buy_price  = `F_PRICE(buy_buf [buy_ptr ]);
wire [15:0] m_sell_price = `F_PRICE(sell_buf[sell_ptr]);
wire [15:0] m_buy_qty    = `F_QTY  (buy_buf [buy_ptr ]);
wire [15:0] m_sell_qty   = `F_QTY  (sell_buf[sell_ptr]);

// Match condition: buy price must be >= sell price
wire match_cond = (m_buy_price >= m_sell_price);

// Trade quantity = min(buy.qty, sell.qty)
wire [15:0] trade_qty   = (m_buy_qty < m_sell_qty) ? m_buy_qty : m_sell_qty;

// Trade price = sell.price (canonical intra-batch rule, Spec §5.2)
wire [15:0] trade_price = m_sell_price;

// Pointer bounds check: both pointers must be within their respective counts
wire ptrs_valid = (buy_ptr  < buy_cnt) &&
                  (sell_ptr < sell_cnt);

// =============================================================================
// Output / status signals
// =============================================================================

// Engine accepts input in IDLE and LOAD states
assign input_ready = state[0] | state[1];  // ST_IDLE | ST_LOAD

// Done pulse fires for exactly one cycle in ST_DONE
assign done = state[7];   // ST_DONE

assign state_dbg = state;

// =============================================================================
// Clocked FSM (single always block — registers only, no latches possible)
// =============================================================================

integer idx;  // loop variable for reset initialisation

always @(posedge clk or negedge rst_n) begin

    if (!rst_n) begin
        // ---- Asynchronous reset ----------------------------------------
        state        <= ST_IDLE;
        buy_cnt      <= 4'd0;
        sell_cnt     <= 4'd0;
        load_cnt     <= 4'd0;
        sort_pass    <= 3'd0;
        sort_idx     <= 3'd0;
        buy_ptr      <= 4'd0;
        sell_ptr     <= 4'd0;
        trade_cnt    <= 4'd0;
        trade_rd_ptr <= 4'd0;
        output_valid <= 1'b0;
        trade_out    <= 128'h0;
        for (idx = 0; idx < BATCH_SIZE; idx = idx + 1) begin
            buy_buf  [idx] <= 128'h0;
            sell_buf [idx] <= 128'h0;
            trade_buf[idx] <= 128'h0;
        end

    end else begin
        case (state)

            // ================================================================
            // ST_IDLE — wait for first order of a new batch
            // ================================================================
            ST_IDLE: begin
                output_valid <= 1'b0;
                if (input_valid) begin
                    // Accept first order of the new batch.
                    // Route by side bit: 1=BUY, 0=SELL
                    if (`F_SIDE(order_in)) begin
                        buy_buf [4'd0] <= order_in;
                        buy_cnt        <= 4'd1;
                        sell_cnt       <= 4'd0;
                    end else begin
                        sell_buf[4'd0] <= order_in;
                        sell_cnt       <= 4'd1;
                        buy_cnt        <= 4'd0;
                    end

                    // Initialise sort / match state for new batch
                    load_cnt     <= 4'd1;
                    sort_pass    <= 3'd0;
                    sort_idx     <= 3'd0;
                    buy_ptr      <= 4'd0;
                    sell_ptr     <= 4'd0;
                    trade_cnt    <= 4'd0;
                    trade_rd_ptr <= 4'd0;

                    // Transition: go directly to sort if batch size is 1
                    state <= (BATCH_SIZE == 1) ? ST_SORT_BUY : ST_LOAD;
                end
            end

            // ================================================================
            // ST_LOAD — accumulate orders 2..BATCH_SIZE
            // ================================================================
            // [Role: order_buffer — accepts & routes incoming order words]
            ST_LOAD: begin
                if (input_valid) begin
                    // Route to buy or sell buffer depending on side bit
                    if (`F_SIDE(order_in)) begin
                        buy_buf [buy_cnt ] <= order_in;
                        buy_cnt            <= buy_cnt  + 4'd1;
                    end else begin
                        sell_buf[sell_cnt] <= order_in;
                        sell_cnt           <= sell_cnt + 4'd1;
                    end
                    load_cnt <= load_cnt + 4'd1;

                    // When last order of batch received: start sort
                    if (load_cnt == (BATCH_SIZE[3:0] - 4'd1)) begin
                        state     <= ST_SORT_BUY;
                        sort_pass <= 3'd0;
                        sort_idx  <= 3'd0;
                    end
                end else if (flush_in && load_cnt >= 4'd1) begin
                    // Force-flush partial batch: at least 1 order must be loaded.
                    // input_valid takes priority (checked first above).
                    state     <= ST_SORT_BUY;
                    sort_pass <= 3'd0;
                    sort_idx  <= 3'd0;
                end
            end

            // ================================================================
            // ST_SORT_BUY — bubble-sort buy_buf by arbitration key
            // ================================================================
            // [Role: sort_unit — sequential N-pass bubble sort, high-price first]
            //
            // Timing: (BATCH_SIZE-1) passes × (BATCH_SIZE-1) idx steps
            //         = 7 × 7 = 49 cycles for BATCH_SIZE=8
            //
            // Each cycle:
            //   1. Check if cmp_b should come before cmp_a (do_swap is combinational)
            //   2. If so, swap buy_buf[sort_idx] ↔ buy_buf[sort_idx+1]
            //   3. Advance sort_idx; at end of pass, advance sort_pass
            ST_SORT_BUY: begin
                // Perform swap if needed (non-blocking → true simultaneous exchange)
                if (do_swap) begin
                    buy_buf[sort_idx    ] <= buy_buf[sort_idx + 3'd1];
                    buy_buf[sort_idx + 3'd1] <= buy_buf[sort_idx    ];
                end

                // Advance counters
                if (sort_idx == (BATCH_SIZE[2:0] - 3'd2)) begin
                    sort_idx <= 3'd0;
                    if (sort_pass == (BATCH_SIZE[2:0] - 3'd2)) begin
                        // All passes complete — transition to SELL sort
                        sort_pass <= 3'd0;
                        state     <= ST_SORT_SELL;
                    end else begin
                        sort_pass <= sort_pass + 3'd1;
                    end
                end else begin
                    sort_idx <= sort_idx + 3'd1;
                end
            end

            // ================================================================
            // ST_SORT_SELL — bubble-sort sell_buf by arbitration key
            // ================================================================
            // [Role: sort_unit — low-price first]
            //
            // Timing: identical to ST_SORT_BUY (49 cycles)
            ST_SORT_SELL: begin
                if (do_swap) begin
                    sell_buf[sort_idx    ] <= sell_buf[sort_idx + 3'd1];
                    sell_buf[sort_idx + 3'd1] <= sell_buf[sort_idx    ];
                end

                if (sort_idx == (BATCH_SIZE[2:0] - 3'd2)) begin
                    sort_idx <= 3'd0;
                    if (sort_pass == (BATCH_SIZE[2:0] - 3'd2)) begin
                        // Both sides sorted — begin matching
                        sort_pass <= 3'd0;
                        state     <= ST_MATCH;
                        buy_ptr   <= 4'd0;
                        sell_ptr  <= 4'd0;
                        trade_cnt <= 4'd0;
                    end else begin
                        sort_pass <= sort_pass + 3'd1;
                    end
                end else begin
                    sort_idx <= sort_idx + 3'd1;
                end
            end

            // ================================================================
            // ST_MATCH — two-pointer greedy matching + arbitration
            // ================================================================
            // [Role: matcher + arbiter]
            //
            // Each cycle: examine (buy_buf[buy_ptr], sell_buf[sell_ptr]).
            //   If buy.price >= sell.price → execute trade, update quantities,
            //                               advance pointer(s) for spent orders.
            //   Else                       → no further matches possible → WRITEBACK.
            //
            // Arbitration is implicit: both sides are fully sorted, so the
            // comparator already resolved all priority conflicts deterministically.
            //
            // Timing: at most (buy_cnt + sell_cnt) cycles; exits as soon as the
            //         crossing condition fails or a pointer is exhausted.
            ST_MATCH: begin
                if (!ptrs_valid || !match_cond) begin
                    // No more possible matches
                    state <= ST_WRITEBACK;
                end else begin
                    // ------ Record trade in trade_buf ------
                    trade_buf[trade_cnt][127:96] <= `F_ID(buy_buf [buy_ptr ]);  // buy_id
                    trade_buf[trade_cnt][ 95:64] <= `F_ID(sell_buf[sell_ptr]);  // sell_id
                    trade_buf[trade_cnt][ 63:48] <= 16'h0000;                   // reserved
                    trade_buf[trade_cnt][ 47:32] <= trade_price;                // trade price
                    trade_buf[trade_cnt][ 31:16] <= trade_qty;                  // trade qty
                    trade_buf[trade_cnt][ 15: 0] <= 16'h0000;                   // reserved
                    trade_cnt <= trade_cnt + 4'd1;

                    // ------ Reduce quantities in place ------
                    buy_buf [buy_ptr ][31:16] <= m_buy_qty  - trade_qty;
                    sell_buf[sell_ptr][31:16] <= m_sell_qty - trade_qty;

                    // ------ Advance pointers for fully consumed orders ------
                    // Non-blocking: both conditions evaluated with pre-update values.
                    // If both become zero in same cycle, both pointers advance. ✓
                    if (m_buy_qty  == trade_qty) buy_ptr  <= buy_ptr  + 4'd1;
                    if (m_sell_qty == trade_qty) sell_ptr <= sell_ptr + 4'd1;
                end
            end

            // ================================================================
            // ST_WRITEBACK — commit residuals, prepare output
            // ================================================================
            // [Role: write_back — in full PS+PL system, PS reads residual orders
            //   from buy_buf/sell_buf via AXI after this state. In standalone RTL,
            //   residuals remain in registers and are visible on output ports.]
            //
            // Timing: 1 cycle
            ST_WRITEBACK: begin
                trade_rd_ptr <= 4'd0;
                state <= (trade_cnt > 4'd0) ? ST_OUTPUT : ST_DONE;
            end

            // ================================================================
            // ST_OUTPUT — stream trade records via valid/ready handshake
            // ================================================================
            // [Timing: one trade per cycle when output_ready is asserted]
            ST_OUTPUT: begin
                if (!output_valid || output_ready) begin
                    // Previous record accepted (or no record pending)
                    if (trade_rd_ptr < trade_cnt) begin
                        output_valid <= 1'b1;
                        trade_out    <= trade_buf[trade_rd_ptr];
                        trade_rd_ptr <= trade_rd_ptr + 4'd1;
                    end else begin
                        // All trades sent
                        output_valid <= 1'b0;
                        state        <= ST_DONE;
                    end
                end
                // If output_valid && !output_ready: hold current trade_out (stall)
            end

            // ================================================================
            // ST_DONE — one-cycle done pulse, then return to IDLE
            // ================================================================
            ST_DONE: begin
                output_valid <= 1'b0;
                state        <= ST_IDLE;
                // 'done' output is driven by state[7]; it is naturally high
                // for exactly one cycle here.
            end

            default: begin
                // Should never reach here in correct operation.
                // Safe recovery: return to IDLE.
                state        <= ST_IDLE;
                output_valid <= 1'b0;
            end

        endcase
    end
end

// =============================================================================
// Clean up macros to prevent namespace pollution in multi-file projects
// =============================================================================
`undef F_TS
`undef F_ID
`undef F_SIDE
`undef F_PRICE
`undef F_QTY

endmodule

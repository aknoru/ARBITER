// =============================================================================
// tb_bame_top.v  —  Testbench for Batched Arbitration Matching Engine
// =============================================================================
//
// Coverage:
//   Test 1 — Batch 1 (8 mixed orders): 5 expected trades, 3 residuals
//   Test 2 — Batch 2 (3 orders, partial flush): 1 expected trade (RTL-standalone)
//   Test 3 — All-BUY batch (8 BUY orders): 0 trades expected
//   Test 4 — Perfect-match batch (equal qty BUY+SELL): 1 trade, 0 residuals
//   Test 5 — Backpressure test: output_ready de-asserted mid-stream
//
// RTL vs CPU note:
//   The RTL operates as a single-batch accelerator (no persistent resting book).
//   Batch 2 in the RTL sees only 3 new orders (not the 4 CPU-resting orders),
//   so it produces 1 trade instead of the CPU's 2 trades.
//   In the full PS+PL system, the PS merges resting+new orders before each batch.
//
// Waveform output:
//   bame_sim.vcd  — view with GTKWave or Vivado simulator
//
// Expected $display output:
//   [T1] PASS: 5 trades match golden values
//   [T2] PASS: 1 trade  matches RTL-standalone expected value
//   [T3] PASS: 0 trades (all-buy batch)
//   [T4] PASS: 1 trade  (perfect match)
//   [T5] PASS: backpressure stall + correct resume
//
// Simulation completion: normal ($finish), no runaway condition.
// =============================================================================

`timescale 1ns / 1ps

module tb_bame_top;

// =============================================================================
// Parameters
// =============================================================================
localparam CLK_PERIOD  = 10;   // 100 MHz → 10 ns period
localparam BATCH_SZ    = 8;
localparam TIMEOUT_CYC = 2000; // watchdog: abort if simulation exceeds this

// =============================================================================
// DUT signals
// =============================================================================
reg          clk;
reg          rst_n;
reg          input_valid;
wire         input_ready;
reg  [127:0] order_in;
wire         output_valid;
reg          output_ready;
wire [127:0] trade_out;
wire         done;
wire [7:0]   state_dbg;
reg          flush_in;

// =============================================================================
// DUT instantiation
// =============================================================================
bame_top #(
    .BATCH_SIZE (BATCH_SZ)
) u_dut (
    .clk          (clk),
    .rst_n        (rst_n),
    .input_valid  (input_valid),
    .input_ready  (input_ready),
    .order_in     (order_in),
    .output_valid (output_valid),
    .output_ready (output_ready),
    .trade_out    (trade_out),
    .flush_in     (flush_in),
    .done         (done),
    .state_dbg    (state_dbg)
);

// =============================================================================
// Clock generation — 100 MHz
// =============================================================================
initial clk = 1'b0;
always  #(CLK_PERIOD/2) clk = ~clk;

// =============================================================================
// Waveform dump  (GTKWave / Vivado simulator compatible)
// =============================================================================
initial begin
    $dumpfile("bame_sim.vcd");
    $dumpvars(0, tb_bame_top);   // dump all signals in this hierarchy
end

// =============================================================================
// Test order arrays
// =============================================================================
//
// Encoding (128-bit word):
//   [127:96] = timestamp   [95:64] = order_id
//   [63]     = side(BUY=1) [47:32] = price    [31:16] = qty
//
// Values verified against tests/orders.mem from Stage 2.

// -- Batch 1: 8 mixed orders (matches orders.txt lines 1-8) --
reg [127:0] batch1 [0:7];
// -- Batch 2: 3 orders (partial batch, orders.txt lines 9-11) --
reg [127:0] batch2 [0:2];
// -- Test 3: 8 all-BUY orders (no possible matches) --
reg [127:0] batch3 [0:7];
// -- Test 4: Perfect-match batch (2 orders: 1 BUY, 1 SELL, equal qty) --
reg [127:0] batch4 [0:1];

// =============================================================================
// Trade capture
// =============================================================================
reg  [127:0] captured [0:31];  // enough for all tests
integer      cap_cnt;          // total trades captured across all tests

// =============================================================================
// State name task (for $display readability)
// =============================================================================
task print_state;
    input [7:0] s;
    case (s)
        8'b00000001: $write("IDLE    ");
        8'b00000010: $write("LOAD    ");
        8'b00000100: $write("SORT_BUY");
        8'b00001000: $write("SORT_SEL");
        8'b00010000: $write("MATCH   ");
        8'b00100000: $write("WRITEBAK");
        8'b01000000: $write("OUTPUT  ");
        8'b10000000: $write("DONE    ");
        default:     $write("???????");
    endcase
endtask

// =============================================================================
// FSM state-change monitor (waveform + log)
// =============================================================================
reg [7:0] prev_state;

always @(posedge clk) begin
    if (state_dbg !== prev_state) begin
        $write("[%5t ns] FSM: ", $time);
        print_state(prev_state);
        $write(" → ");
        print_state(state_dbg);
        $write("\n");
        prev_state <= state_dbg;
    end
end

// =============================================================================
// Trade output monitor — captures every accepted trade
// =============================================================================
always @(posedge clk) begin
    if (output_valid && output_ready) begin
        captured[cap_cnt] = trade_out;
        $display("[%5t ns] TRADE captured[%0d]: buy_id=%-5d sell_id=%-5d price=%-5d qty=%0d",
            $time, cap_cnt,
            trade_out[127:96],   // buy_id
            trade_out[ 95:64],   // sell_id
            trade_out[ 47:32],   // price
            trade_out[ 31:16]);  // qty
        cap_cnt = cap_cnt + 1;
    end
end

// =============================================================================
// Task: reset DUT
// =============================================================================
task do_reset;
    begin
        rst_n        = 1'b0;
        input_valid  = 1'b0;
        flush_in     = 1'b0;
        order_in     = 128'h0;
        output_ready = 1'b1;
        cap_cnt      = 0;
        prev_state   = 8'b0;
        repeat(5) @(posedge clk);
        #1 rst_n = 1'b1;
        @(posedge clk);
        $display("[%5t ns] Reset released. DUT in IDLE.", $time);
    end
endtask

// =============================================================================
// Task: send one order (waits for input_ready, presents on next available cycle)
// =============================================================================
task send_order;
    input [127:0] ord;
    begin
        // Wait until engine is ready to accept
        while (!input_ready) @(posedge clk);
        // Drive order after the posedge so it's stable for the next posedge
        #1;
        order_in    = ord;
        input_valid = 1'b1;
        // Order is sampled at the next rising edge
        @(posedge clk);
        #1;
        input_valid = 1'b0;
        order_in    = 128'h0;
    end
endtask

// Note: send_batch task removed; callers use an inline for-loop with send_order()
// to avoid non-standard array-type task ports (Verilog-2001 compatible).

// =============================================================================
// Task: flush (force partial batch processing)
// =============================================================================
task do_flush;
    begin
        // Assert flush_in for 2 cycles
        while (!input_ready) @(posedge clk); // wait to be in LOAD
        #1 flush_in = 1'b1;
        @(posedge clk);
        @(posedge clk);
        #1 flush_in = 1'b0;
        $display("[%5t ns] flush_in asserted → partial batch triggered.", $time);
    end
endtask

// =============================================================================
// Task: wait for batch done with watchdog
// =============================================================================
integer watchdog;
task wait_done;
    begin
        watchdog = 0;
        while (!done && watchdog < TIMEOUT_CYC) begin
            @(posedge clk);
            watchdog = watchdog + 1;
        end
        if (watchdog >= TIMEOUT_CYC) begin
            $display("ERROR: watchdog expired waiting for done! state=%b", state_dbg);
            $finish;
        end
        $display("[%5t ns] DONE pulse observed.", $time);
        @(posedge clk); // consume the DONE cycle
    end
endtask

// =============================================================================
// Task: check one captured trade against expected values
// =============================================================================
integer pass_cnt, fail_cnt;

task check_trade;
    input integer    slot;
    input [31:0]     exp_buy;
    input [31:0]     exp_sell;
    input [15:0]     exp_price;
    input [15:0]     exp_qty;
    reg              ok;
    begin
        ok = (captured[slot][127:96] === exp_buy)   &&
             (captured[slot][ 95:64] === exp_sell)  &&
             (captured[slot][ 47:32] === exp_price) &&
             (captured[slot][ 31:16] === exp_qty);
        if (ok) begin
            $display("  PASS trade[%0d]: buy_id=%0d sell_id=%0d price=%0d qty=%0d",
                slot, exp_buy, exp_sell, exp_price, exp_qty);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL trade[%0d]:", slot);
            $display("       expected: buy_id=%0d sell_id=%0d price=%0d qty=%0d",
                exp_buy, exp_sell, exp_price, exp_qty);
            $display("       actual:   buy_id=%0d sell_id=%0d price=%0d qty=%0d",
                captured[slot][127:96], captured[slot][95:64],
                captured[slot][47:32],  captured[slot][31:16]);
            fail_cnt = fail_cnt + 1;
        end
    end
endtask

// =============================================================================
// Task: check that a slot is VALID (trade existed) or does NOT exist
// =============================================================================
task check_trade_count;
    input integer expected_total;
    input integer start_slot;   // first slot of this test
    begin
        if ((cap_cnt - start_slot) === expected_total) begin
            $display("  PASS trade count: %0d trades", expected_total);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL trade count: expected %0d, got %0d",
                expected_total, cap_cnt - start_slot);
            fail_cnt = fail_cnt + 1;
        end
    end
endtask

// =============================================================================
// Initialise order arrays
// =============================================================================
initial begin
    // ---- Batch 1 (Test 1): orders from tests/orders.mem ----
    // Format: {timestamp(32), order_id(32), side(1)+rsv(15), price(16), qty(16), rsv(16)}
    //         = {ts, id, 8000|0000, price, qty, 0000}
    // BUY side field = 16'h8000 in [63:48]; SELL = 16'h0000
    batch1[0] = 128'h00000001_00000065_8000_0064_000A_0000; // ts=1  id=101 BUY  p=100 q=10
    batch1[1] = 128'h00000002_00000066_0000_0063_0005_0000; // ts=2  id=102 SELL p=99  q=5
    batch1[2] = 128'h00000003_00000067_8000_0065_0003_0000; // ts=3  id=103 BUY  p=101 q=3
    batch1[3] = 128'h00000004_00000068_0000_0064_0008_0000; // ts=4  id=104 SELL p=100 q=8
    batch1[4] = 128'h00000005_00000069_8000_0062_0006_0000; // ts=5  id=105 BUY  p=98  q=6
    batch1[5] = 128'h00000006_0000006A_0000_0066_0004_0000; // ts=6  id=106 SELL p=102 q=4
    batch1[6] = 128'h00000007_0000006B_8000_0067_0007_0000; // ts=7  id=107 BUY  p=103 q=7
    batch1[7] = 128'h00000008_0000006C_0000_0064_0002_0000; // ts=8  id=108 SELL p=100 q=2

    // ---- Batch 2 (Test 2): 3 orders, partial batch ----
    batch2[0] = 128'h00000009_0000006D_8000_0066_0004_0000; // ts=9  id=109 BUY  p=102 q=4
    batch2[1] = 128'h0000000A_0000006E_0000_0062_0003_0000; // ts=10 id=110 SELL p=98  q=3
    batch2[2] = 128'h0000000B_0000006F_8000_0063_0002_0000; // ts=11 id=111 BUY  p=99  q=2

    // ---- Batch 3 (Test 3): 8 all-BUY orders; no sells → 0 trades ----
    batch3[0] = 128'h00010001_000004B0_8000_0064_0001_0000; // ts=65537 id=1200 BUY p=100 q=1
    batch3[1] = 128'h00010002_000004B1_8000_0050_0002_0000; // ts=65538 id=1201 BUY p=80  q=2
    batch3[2] = 128'h00010003_000004B2_8000_0078_0003_0000; // ts=65539 id=1202 BUY p=120 q=3
    batch3[3] = 128'h00010004_000004B3_8000_0055_0004_0000; // ts=65540 id=1203 BUY p=85  q=4
    batch3[4] = 128'h00010005_000004B4_8000_0096_0005_0000; // ts=65541 id=1204 BUY p=150 q=5
    batch3[5] = 128'h00010006_000004B5_8000_0041_0006_0000; // ts=65542 id=1205 BUY p=65  q=6
    batch3[6] = 128'h00010007_000004B6_8000_00C8_0007_0000; // ts=65543 id=1206 BUY p=200 q=7
    batch3[7] = 128'h00010008_000004B7_8000_0032_0008_0000; // ts=65544 id=1207 BUY p=50  q=8

    // ---- Batch 4 (Test 4): perfect match — BUY qty=10, SELL qty=10, same price ----
    batch4[0] = 128'h00020001_000007D0_8000_0064_000A_0000; // ts=131073 id=2000 BUY  p=100 q=10
    batch4[1] = 128'h00020002_000007D1_0000_0064_000A_0000; // ts=131074 id=2001 SELL p=100 q=10
end

// =============================================================================
// MAIN TEST PROGRAM
// =============================================================================
integer t1_start, t2_start, t3_start, t4_start, t5_start;
integer i;

initial begin
    pass_cnt = 0;
    fail_cnt = 0;

    $display("=======================================================");
    $display("  BAME RTL Testbench — bame_top  (BATCH_SIZE=%0d)", BATCH_SZ);
    $display("=======================================================\n");

    // =========================================================================
    // RESET
    // =========================================================================
    do_reset;
    output_ready = 1'b1;

    // =========================================================================
    // TEST 1 — Batch 1: 8 mixed orders
    // Expected trades (from Stage 2 hand-derivation + C++ golden output):
    //   [0] buy=107 sell=102 price=99  qty=5
    //   [1] buy=107 sell=104 price=100 qty=2
    //   [2] buy=103 sell=104 price=100 qty=3
    //   [3] buy=101 sell=104 price=100 qty=3
    //   [4] buy=101 sell=108 price=100 qty=2
    // =========================================================================
    $display("--- TEST 1: Batch 1 (8 mixed orders, expect 5 trades) ---");
    t1_start = cap_cnt;

    // Send all 8 orders back-to-back
    for (i = 0; i < 8; i = i + 1) send_order(batch1[i]);

    wait_done;

    $display("  Checking %0d captured trades from slot %0d:", cap_cnt - t1_start, t1_start);
    check_trade_count(5, t1_start);
    check_trade(t1_start+0, 32'd107, 32'd102, 16'd99,  16'd5);
    check_trade(t1_start+1, 32'd107, 32'd104, 16'd100, 16'd2);
    check_trade(t1_start+2, 32'd103, 32'd104, 16'd100, 16'd3);
    check_trade(t1_start+3, 32'd101, 32'd104, 16'd100, 16'd3);
    check_trade(t1_start+4, 32'd101, 32'd108, 16'd100, 16'd2);

    // =========================================================================
    // TEST 2 — Batch 2: 3 orders (partial batch, flush required)
    // RTL-standalone expected trades (no persistent book):
    //   [0] buy=109 sell=110 price=98 qty=3
    //   Note: CPU golden has 2 trades because it carries resting SELL-106 from
    //         Batch 1. The standalone RTL only sees the 3 new orders.
    // =========================================================================
    $display("\n--- TEST 2: Batch 2 (3 orders, partial flush, expect 1 trade) ---");
    $display("  Note: standalone RTL has no resting book; CPU golden shows 2 trades.");
    t2_start = cap_cnt;
    repeat(3) @(posedge clk);

    // Send 3 orders, then flush
    for (i = 0; i < 3; i = i + 1) send_order(batch2[i]);
    do_flush;

    wait_done;

    check_trade_count(1, t2_start);
    check_trade(t2_start+0, 32'd109, 32'd110, 16'd98, 16'd3);

    // =========================================================================
    // TEST 3 — All-BUY batch: 8 all-BUY orders → 0 trades (no sells)
    // =========================================================================
    $display("\n--- TEST 3: All-BUY batch (8 orders, expect 0 trades) ---");
    t3_start = cap_cnt;
    repeat(3) @(posedge clk);

    for (i = 0; i < 8; i = i + 1) send_order(batch3[i]);

    wait_done;

    check_trade_count(0, t3_start);
    if ((cap_cnt - t3_start) === 0)
        $display("  PASS: no spurious trades generated for all-buy batch.");

    // =========================================================================
    // TEST 4 — Perfect match: 1 BUY q=10 vs 1 SELL q=10 at same price
    // Expected: 1 trade (buy=2000, sell=2001, price=100, qty=10), 0 residuals
    // =========================================================================
    $display("\n--- TEST 4: Perfect match (2 orders, expect 1 trade, 0 residuals) ---");
    t4_start = cap_cnt;
    repeat(3) @(posedge clk);

    // Send only 2 orders, then flush
    for (i = 0; i < 2; i = i + 1) send_order(batch4[i]);
    do_flush;

    wait_done;

    check_trade_count(1, t4_start);
    check_trade(t4_start+0, 32'd2000, 32'd2001, 16'd100, 16'd10);

    // =========================================================================
    // TEST 5 — Backpressure: de-assert output_ready mid-stream
    // Send Batch 1 again; stall output_ready after 2nd trade for 4 cycles.
    // All 5 trades must eventually be received correctly.
    // =========================================================================
    $display("\n--- TEST 5: Backpressure stall (Batch 1 repeat, output_ready toggled) ---");
    t5_start = cap_cnt;
    repeat(3) @(posedge clk);

    output_ready = 1'b1;

    // Re-send Batch 1
    for (i = 0; i < 8; i = i + 1) send_order(batch1[i]);

    // Deassert output_ready after 2 trades are captured.
    // Verilog-2001 compatible: poll cap_cnt on every posedge clock.
    fork
        begin : bp_driver
            // Spin until 2 trades from this test have been captured
            while ((cap_cnt - t5_start) < 2) @(posedge clk);
            #1 output_ready = 1'b0;
            $display("[%5t ns] Backpressure: output_ready de-asserted.", $time);
            repeat(4) @(posedge clk);
            #1 output_ready = 1'b1;
            $display("[%5t ns] Backpressure: output_ready re-asserted.", $time);
        end
        begin : bp_wait
            wait_done;
        end
    join

    // Restore output_ready and wait a few cycles for tail trades
    output_ready = 1'b1;
    repeat(10) @(posedge clk);

    check_trade_count(5, t5_start);
    check_trade(t5_start+0, 32'd107, 32'd102, 16'd99,  16'd5);
    check_trade(t5_start+1, 32'd107, 32'd104, 16'd100, 16'd2);
    check_trade(t5_start+2, 32'd103, 32'd104, 16'd100, 16'd3);
    check_trade(t5_start+3, 32'd101, 32'd104, 16'd100, 16'd3);
    check_trade(t5_start+4, 32'd101, 32'd108, 16'd100, 16'd2);

    // =========================================================================
    // FINAL REPORT
    // =========================================================================
    repeat(5) @(posedge clk);

    $display("\n=======================================================");
    $display("  SIMULATION COMPLETE");
    $display("  PASS: %0d    FAIL: %0d    TOTAL trades captured: %0d",
             pass_cnt, fail_cnt, cap_cnt);
    if (fail_cnt == 0)
        $display("  *** ALL TESTS PASSED ***");
    else
        $display("  *** %0d TEST(S) FAILED — REVIEW OUTPUT ABOVE ***", fail_cnt);
    $display("=======================================================\n");

    $finish;
end

// =============================================================================
// Global watchdog: abort simulation if it runs too long
// =============================================================================
initial begin
    #(TIMEOUT_CYC * CLK_PERIOD * 20);  // much larger than any expected run time
    $display("FATAL: global simulation timeout exceeded!");
    $finish;
end

endmodule

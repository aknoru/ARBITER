`timescale 1ns / 1ps

module tb_top;

// =============================================================================
// Parameters
// =============================================================================
localparam CLK_PERIOD  = 10;   // 100 MHz → 10 ns period
localparam BATCH_SZ    = 8;
localparam TIMEOUT_CYC = 5000;

// =============================================================================
// DUT signals
// =============================================================================
reg          clk;
reg          rst;
reg          input_valid;
wire         input_ready;
reg  [144:0] order_in;
wire         output_valid;
reg          output_ready;
wire [175:0] trade_out;
wire         done;
wire [6:0]   state_dbg;
reg          flush_in;

// =============================================================================
// Memory for CSV -> Rust -> .mem pipeline
// =============================================================================
reg [144:0] order_mem [0:1023];
integer     mem_lines = 0;

// =============================================================================
// DUT instantiation
// =============================================================================
bame_top #(
    .BATCH_SIZE (BATCH_SZ)
) u_dut (
    .clk          (clk),
    .rst          (rst),
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
// Clock generation
// =============================================================================
initial clk = 1'b0;
always  #(CLK_PERIOD/2) clk = ~clk;

// =============================================================================
// Waveform dump
// =============================================================================
initial begin
    $dumpfile("wave.vcd");
    $dumpvars(0, tb_top);
end

// =============================================================================
// X/Z State detector — only fires after reset has been released
// =============================================================================
always @(posedge clk) begin
    if (!rst && (state_dbg === 7'hx || state_dbg === 7'hz)) begin
        $display("FATAL: X/Z state detected in FSM after reset. Simulation aborted.");
        $finish;
    end
end

// =============================================================================
// MAIN TEST PROGRAM
// =============================================================================
integer load_idx = 0;
integer cap_cnt = 0;

initial begin
    $display("=======================================================");
    $display("  BAME RTL Testbench — Hardware Validation Pipeline");
    $display("=======================================================");

    // Read memories populated by Rust CSV pipeline
    // For local tests where 'orders.mem' might not exist immediately, we try to open it
    $readmemb("tests/orders.mem", order_mem);
    
    // Find how many lines were populated
    while (order_mem[mem_lines] !== 145'hx && mem_lines < 1024) begin
        mem_lines = mem_lines + 1;
    end
    
    $display("INFO: Loaded %0d orders from tests/orders.mem", mem_lines);

    // Initial resets
    rst          = 1'b1;
    input_valid  = 1'b0;
    flush_in     = 1'b0;
    order_in     = 145'h0;
    output_ready = 1'b1;

    repeat(5) @(posedge clk);
    #1 rst = 1'b0;
    @(posedge clk);
    $display("[%5t ns] Reset released. Beginning stream.", $time);

    // Stream orders into DUT
    while (load_idx < mem_lines) begin
        while (!input_ready) @(posedge clk);
        #1;
        order_in    = order_mem[load_idx];
        input_valid = 1'b1;
        @(posedge clk);
        #1;
        input_valid = 1'b0;
        load_idx    = load_idx + 1;
    end

    // Signal flush for any partial batches
    if (mem_lines % BATCH_SZ != 0) begin
        while (!input_ready) @(posedge clk);
        #1 flush_in = 1'b1;
        @(posedge clk);
        #1 flush_in = 1'b0;
    end

    // Wait until engine finishes resolving the last batch
    wait (done == 1'b1);
    repeat(10) @(posedge clk);
    
    $display("=======================================================");
    $display("  SIMULATION COMPLETE");
    $display("  TOTAL orders loaded : %0d", mem_lines);
    $display("  TOTAL trades emitted: %0d", cap_cnt);
    $display("=======================================================");
    $finish;
end

// =============================================================================
// Capture output
// =============================================================================
always @(posedge clk) begin
    if (output_valid && output_ready) begin
        $display("[%5t ns] TRADE  buy_id=%-0d  sell_id=%-0d  price=%-0d  qty=%-0d",
            $time,
            trade_out[175:112],   // buy_id
            trade_out[111:48],    // sell_id
            trade_out[ 47:32],    // price
            trade_out[ 31:0]);    // qty
        cap_cnt = cap_cnt + 1;
    end
end

// Watchdog
initial begin
    #(TIMEOUT_CYC * CLK_PERIOD);
    $display("FATAL: Watchdog timer expired.");
    $finish;
end

endmodule

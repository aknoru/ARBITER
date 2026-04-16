// =============================================================================
// bame_axi_wrapper.v  —  AXI-Stream & AXI-Lite Wrapper for BAME Engine
// =============================================================================
// This wrapper bridges the 145-bit BAME engine to standard AXI interfaces:
// 1. S_AXI_LITE (32-bit): Control and Status registers
// 2. S_AXIS_ORDERS (256-bit): Batch Ingress
// 3. M_AXIS_TRADES (256-bit): Trade Egress
// =============================================================================

`timescale 1ns / 1ps

module bame_axi_wrapper #(
    parameter integer C_S_AXI_LITE_ADDR_WIDTH = 4,
    parameter integer C_S_AXI_LITE_DATA_WIDTH = 32,
    parameter integer BATCH_SIZE = 8
)(
    // ---- Global System Signals ----
    input  wire        aclk,
    input  wire        aresetn,

    // ---- Slave AXI-Lite (Control/Status) ----
    input  wire [C_S_AXI_LITE_ADDR_WIDTH-1 : 0] s_axi_awaddr,
    input  wire [2 : 0]                         s_axi_awprot,
    input  wire                                 s_axi_awvalid,
    output wire                                 s_axi_awready,
    input  wire [C_S_AXI_LITE_DATA_WIDTH-1 : 0] s_axi_wdata,
    input  wire [(C_S_AXI_LITE_DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input  wire                                 s_axi_wvalid,
    output wire                                 s_axi_wready,
    output wire [1 : 0]                         s_axi_bresp,
    output wire                                 s_axi_bvalid,
    input  wire                                 s_axi_bready,
    input  wire [C_S_AXI_LITE_ADDR_WIDTH-1 : 0] s_axi_araddr,
    input  wire [2 : 0]                         s_axi_arprot,
    input  wire                                 s_axi_arvalid,
    output wire                                 s_axi_arready,
    output wire [C_S_AXI_LITE_DATA_WIDTH-1 : 0] s_axi_rdata,
    output wire [1 : 0]                         s_axi_rresp,
    output wire                                 s_axi_rvalid,
    input  wire                                 s_axi_rready,

    // ---- Slave AXI-Stream (Order Ingress) ----
    input  wire [255 : 0] s_axis_orders_tdata,
    input  wire           s_axis_orders_tvalid,
    output wire           s_axis_orders_tready,

    // ---- Master AXI-Stream (Trade Egress) ----
    output wire [255 : 0] m_axis_trades_tdata,
    output wire           m_axis_trades_tvalid,
    input  wire           m_axis_trades_tready,

    // ---- Interrupt ----
    output wire           irq
);

    // ---- Internal Registers ----
    reg [C_S_AXI_LITE_DATA_WIDTH-1:0] slv_reg_control; // Offset 0x0
    reg [C_S_AXI_LITE_DATA_WIDTH-1:0] slv_reg_status;  // Offset 0x4
    
    // ---- BAME Core Instantiation ----
    wire        core_rst      = !aresetn | slv_reg_control[0];
    wire        core_input_valid;
    wire        core_input_ready;
    wire [144:0] core_order_in;
    wire        core_output_valid;
    wire        core_output_ready;
    wire [175:0] core_trade_out;
    wire        core_flush    = slv_reg_control[1];
    wire        core_done;
    wire [6:0]  core_state;

    bame_top #(
        .BATCH_SIZE(BATCH_SIZE)
    ) bame_core_inst (
        .clk          (aclk),
        .rst          (core_rst),
        .input_valid  (core_input_valid),
        .input_ready  (core_input_ready),
        .order_in     (core_order_in),
        .output_valid (core_output_valid),
        .output_ready (core_output_ready),
        .trade_out    (core_trade_out),
        .flush_in     (core_flush),
        .done         (core_done),
        .state_dbg    (core_state)
    );

    // ---- AXI-Lite Write Logic (Simplified) ----
    assign s_axi_awready = 1'b1;
    assign s_axi_wready  = 1'b1;
    assign s_axi_bresp   = 2'b00; // OKAY
    assign s_axi_bvalid  = s_axi_awvalid && s_axi_wvalid;

    always @(posedge aclk) begin
        if (!aresetn) begin
            slv_reg_control <= 32'h0;
        end else if (s_axi_awvalid && s_axi_wvalid) begin
            if (s_axi_awaddr[3:2] == 2'b00) begin
                slv_reg_control <= s_axi_wdata;
            end
        end
    end

    // ---- AXI-Lite Read Logic ----
    assign s_axi_arready = 1'b1;
    assign s_axi_rresp   = 2'b00;
    assign s_axi_rvalid  = s_axi_arvalid;
    assign s_axi_rdata   = (s_axi_araddr[3:2] == 2'b00) ? slv_reg_control : 
                           (s_axi_araddr[3:2] == 2'b01) ? {25'h0, core_state} : 32'h0;

    // ---- AXI-Stream Egress (Trades) ----
    assign m_axis_trades_tdata[175:0] = core_trade_out;
    assign m_axis_trades_tdata[255:176] = 80'h0;
    assign m_axis_trades_tvalid      = core_output_valid;
    assign core_output_ready         = m_axis_trades_tready;

    // ---- AXI-Stream Ingress (Orders) ----
    assign core_order_in         = s_axis_orders_tdata[144:0];
    assign core_input_valid      = s_axis_orders_tvalid;
    assign s_axis_orders_tready  = core_input_ready;

    // ---- Interrupt Logic ----
    assign irq = core_done;

endmodule

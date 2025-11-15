`timescale 1ns/1ps
`default_nettype none

/**
 * 模块名: tpu_verification_top
 * 功能: 
 * 1. 实例化 Control Unit (大脑)
 * 2. 实例化 TPU Core (身体)
 * 3. 将 CU 和 Core 内部连接
 * 4. 向外部 Testbench 暴露 Host/AXI 接口
 */
module tpu_verification_top #(
    parameter int SYSTOLIC_ARRAY_WIDTH = 16,
    parameter int DATA_WIDTH_IN        = 8,
    parameter int DATA_WIDTH_ACCUM     = 32,
    parameter int ADDR_WIDTH           = 10,
    parameter int CSR_ADDR_WIDTH       = 8
)(
    input logic clk,
    input logic rst,

    // ========================================================================
    // 1. AXI-Lite (CSR) 接口 (暴露给 Testbench)
    // ========================================================================
    input logic [CSR_ADDR_WIDTH-1:0] csr_addr,
    input logic                      csr_wr_en,
    input logic [31:0]               csr_wr_data,
    input logic                      csr_rd_en,
    output logic [31:0]              csr_rd_data,

    // ========================================================================
    // 2. AXI-Master 接口 (暴露给 Testbench)
    // ========================================================================
    // --- CU -> Testbench (模拟 AXI Master) ---
    output logic                         axi_master_start_pulse,
    output logic [31:0]                  axi_master_dest_addr,
    output logic [ADDR_WIDTH-1:0]      axi_master_src_addr,
    output logic [15:0]                  axi_master_length,
    input logic                          axi_master_done_irq,  // Testbench 模拟 Done
    // --- Testbench -> Core (模拟 AXI Master) ---
    input logic [ADDR_WIDTH-1:0]       axim_rd_addr_in,
    input logic                        axim_rd_en_in,
    output logic [DATA_WIDTH_ACCUM-1:0] axim_rd_data_out [SYSTOLIC_ARRAY_WIDTH],

    // ========================================================================
    // 3. Host Write 接口 (暴露给 Testbench)
    // ========================================================================
    input logic [ADDR_WIDTH-1:0]       host_wr_addr_in,
    input logic                        host_wr_en_in,
    input logic [DATA_WIDTH_ACCUM-1:0] host_wr_data_in [SYSTOLIC_ARRAY_WIDTH]
);

    localparam W = SYSTOLIC_ARRAY_WIDTH;

    // ========================================================================
    // 内部连线: Control Unit <--> TPU Core
    // ========================================================================
    
    // --- 状态 ---
    logic core_writeback_valid; // Core -> CU

    // --- A-Flow (Input) ---
    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_a;
    logic                  ctrl_rd_en_a;
    logic                  ctrl_a_valid;
    logic                  ctrl_a_switch;
    
    // --- B-Flow (Weight) ---
    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_b;
    logic                  ctrl_rd_en_b;
    logic                  ctrl_b_accept_w;
    logic [$clog2(W)-1:0]    ctrl_b_weight_index;
    
    // --- C-Flow (Bias) ---
    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_c;
    logic                  ctrl_rd_en_c;
    
    // --- D-Flow (Result) ---
    logic [ADDR_WIDTH-1:0] ctrl_wr_addr_d;
    
    // --- Masks ---
    logic [W-1:0] ctrl_row_mask;
    logic [W-1:0] ctrl_col_mask;
    
    // --- VPU ---
    logic [2:0] ctrl_vpu_mode;


    // ========================================================================
    // 实例化 1: Control Unit (大脑)
    // ========================================================================
    control_unit #(
        .SYSTOLIC_ARRAY_WIDTH(W),
        .ADDR_WIDTH(ADDR_WIDTH),
        .CSR_ADDR_WIDTH(CSR_ADDR_WIDTH)
    ) cu_inst (
        .clk(clk),
        .rst(rst),

        // AXI-Lite (CSR)
        .csr_addr(csr_addr),
        .csr_wr_en(csr_wr_en),
        .csr_wr_data(csr_wr_data),
        .csr_rd_en(csr_rd_en),
        .csr_rd_data(csr_rd_data),

        // AXI-Master (Control)
        .axi_master_start_pulse(axi_master_start_pulse),
        .axi_master_dest_addr(axi_master_dest_addr),
        .axi_master_src_addr(axi_master_src_addr),
        .axi_master_length(axi_master_length),
        .axi_master_done_irq(axi_master_done_irq),

        // Core 状态
        .core_writeback_valid(core_writeback_valid),

        // Core 控制
        .ctrl_rd_addr_a(ctrl_rd_addr_a),
        .ctrl_rd_en_a(ctrl_rd_en_a),
        .ctrl_a_valid(ctrl_a_valid),
        .ctrl_a_switch(ctrl_a_switch),
        .ctrl_rd_addr_b(ctrl_rd_addr_b),
        .ctrl_rd_en_b(ctrl_rd_en_b),
        .ctrl_b_accept_w(ctrl_b_accept_w),
        .ctrl_b_weight_index(ctrl_b_weight_index),
        .ctrl_rd_addr_c(ctrl_rd_addr_c),
        .ctrl_rd_en_c(ctrl_rd_en_c),
        .ctrl_wr_addr_d(ctrl_wr_addr_d),
        .ctrl_row_mask(ctrl_row_mask),
        .ctrl_col_mask(ctrl_col_mask),
        .ctrl_vpu_mode(ctrl_vpu_mode)
    );

    // ========================================================================
    // 实例化 2: TPU Core (身体)
    // ========================================================================
    tpu_core #(
        .SYSTOLIC_ARRAY_WIDTH(W),
        .DATA_WIDTH_IN(DATA_WIDTH_IN),
        .DATA_WIDTH_ACCUM(DATA_WIDTH_ACCUM),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) core_inst (
        .clk(clk),
        .rst(rst),

        // Host Write
        .host_wr_addr_in(host_wr_addr_in),
        .host_wr_en_in(host_wr_en_in),
        .host_wr_data_in(host_wr_data_in),

        // AXI Master Read
        .axim_rd_addr_in(axim_rd_addr_in),
        .axim_rd_en_in(axim_rd_en_in),
        .axim_rd_data_out(axim_rd_data_out),

        // CU 控制信号
        .ctrl_rd_addr_a(ctrl_rd_addr_a),
        .ctrl_rd_en_a(ctrl_rd_en_a),
        .ctrl_rd_addr_b(ctrl_rd_addr_b),
        .ctrl_rd_en_b(ctrl_rd_en_b),
        .ctrl_rd_addr_c(ctrl_rd_addr_c),
        .ctrl_rd_en_c(ctrl_rd_en_c),
        .ctrl_wr_addr_d(ctrl_wr_addr_d),
        .ctrl_a_valid(ctrl_a_valid),
        .ctrl_a_switch(ctrl_a_switch),
        .ctrl_b_accept_w(ctrl_b_accept_w),
        .ctrl_b_weight_index(ctrl_b_weight_index),
        .ctrl_vpu_mode(ctrl_vpu_mode),
        .ctrl_row_mask(ctrl_row_mask),
        .ctrl_col_mask(ctrl_col_mask),

        // Core 状态
        .core_writeback_valid(core_writeback_valid)
    );

endmodule
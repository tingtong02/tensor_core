`timescale 1ns/1ps
`default_nettype none

/**
 * 模块名: top_verification
 * 功能: 整合 control_unit 和 tpu_core
 * 职责: 1. 例化 control_unit 和 tpu_core
 * 2. 连接所有内部 ctrl_* 信号
 * 3. 将所有外部接口 (CSR, Host, AXI Master) 暴露给 testbench
 */
module top_verification #(
    // --- 核心参数 ---
    parameter int SYSTOLIC_ARRAY_WIDTH = 16,
    parameter int DATA_WIDTH_IN        = 8,   // Systolic 输入位宽 (int8)
    parameter int DATA_WIDTH_ACCUM     = 32,  // 累加/VPU/Buffer 位宽 (int32)
    parameter int ADDR_WIDTH           = 10,  // Buffer 地址深度
    parameter int CSR_ADDR_WIDTH       = 8    // CSR 地址宽度
)(
    input logic clk,
    input logic rst,

    // ========================================================================
    // 1. CSR 接口 (来自 Testbench, 去往 Control Unit)
    // ========================================================================
    input logic [CSR_ADDR_WIDTH-1:0] csr_addr,
    input logic                      csr_wr_en,
    input logic [31:0]               csr_wr_data,
    input logic                      csr_rd_en,
    output logic [31:0]              csr_rd_data,

    // ========================================================================
    // 2. Host 接口 (来自 Testbench, 去往 TPU Core)
    // ========================================================================
    input logic [ADDR_WIDTH-1:0]       host_wr_addr_in,
    input logic                        host_wr_en_in,
    input logic [DATA_WIDTH_ACCUM-1:0] host_wr_data_in [SYSTOLIC_ARRAY_WIDTH],

    // ========================================================================
    // 3. AXI Master 接口 (去/来自 Testbench)
    // ========================================================================
    // 3a. 来自 Control Unit
    output logic                         axi_master_start_pulse,
    output logic [31:0]                  axi_master_dest_addr,
    output logic [ADDR_WIDTH-1:0]      axi_master_src_addr,
    output logic [15:0]                  axi_master_length,
    input logic                          axi_master_done_irq,
    
    // 3b. 去/来自 TPU Core
    input logic [ADDR_WIDTH-1:0]       axim_rd_addr_in,
    input logic                        axim_rd_en_in,
    output logic [DATA_WIDTH_ACCUM-1:0] axim_rd_data_out [SYSTOLIC_ARRAY_WIDTH]
);

    // --- 内部连线: Control Unit <-> TPU Core ---
    
    // 状态: TPU Core -> Control Unit
    logic core_writeback_valid;

    // A-Flow: Control Unit -> TPU Core
    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_a;
    logic                  ctrl_rd_en_a;
    logic                  ctrl_a_valid;
    logic                  ctrl_a_switch;
    
    // B-Flow: Control Unit -> TPU Core
    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_b;
    logic                  ctrl_rd_en_b;
    logic                  ctrl_b_accept_w;
    logic [$clog2(SYSTOLIC_ARRAY_WIDTH)-1:0] ctrl_b_weight_index;
    
    // C-Flow: Control Unit -> TPU Core
    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_c;
    logic                  ctrl_rd_en_c;
    logic [2:0]            ctrl_vpu_mode;
    
    // D-Flow: Control Unit -> TPU Core
    logic [ADDR_WIDTH-1:0] ctrl_wr_addr_d;
    
    // Masking: Control Unit -> TPU Core
    logic [SYSTOLIC_ARRAY_WIDTH-1:0] ctrl_row_mask;
    logic [SYSTOLIC_ARRAY_WIDTH-1:0] ctrl_col_mask;


    // ========================================================================
    // 例化 1: Control Unit
    // ========================================================================
    control_unit #(
        .SYSTOLIC_ARRAY_WIDTH(SYSTOLIC_ARRAY_WIDTH),
        .ADDR_WIDTH          (ADDR_WIDTH),
        .CSR_ADDR_WIDTH      (CSR_ADDR_WIDTH)
    ) cu_inst (
        .clk(clk),
        .rst(rst),

        // CSR 接口 (连接到顶层)
        .csr_addr(csr_addr),
        .csr_wr_en(csr_wr_en),
        .csr_wr_data(csr_wr_data),
        .csr_rd_en(csr_rd_en),
        .csr_rd_data(csr_rd_data),

        // AXI Master 接口 (连接到顶层)
        .axi_master_start_pulse(axi_master_start_pulse),
        .axi_master_dest_addr  (axi_master_dest_addr),
        .axi_master_src_addr   (axi_master_src_addr),
        .axi_master_length     (axi_master_length),
        .axi_master_done_irq   (axi_master_done_irq),

        // TPU Core 状态 (来自 core_inst)
        .core_writeback_valid(core_writeback_valid),

        // TPU Core 控制 (去往 core_inst)
        .ctrl_rd_addr_a     (ctrl_rd_addr_a),
        .ctrl_rd_en_a       (ctrl_rd_en_a),
        .ctrl_a_valid       (ctrl_a_valid),
        .ctrl_a_switch      (ctrl_a_switch),
        .ctrl_rd_addr_b     (ctrl_rd_addr_b),
        .ctrl_rd_en_b       (ctrl_rd_en_b),
        .ctrl_b_accept_w    (ctrl_b_accept_w),
        .ctrl_b_weight_index(ctrl_b_weight_index),
        .ctrl_rd_addr_c     (ctrl_rd_addr_c),
        .ctrl_rd_en_c       (ctrl_rd_en_c),
        .ctrl_wr_addr_d     (ctrl_wr_addr_d),
        .ctrl_row_mask      (ctrl_row_mask),
        .ctrl_col_mask      (ctrl_col_mask),
        .ctrl_vpu_mode      (ctrl_vpu_mode)
    );

    // ========================================================================
    // 例化 2: TPU Core
    // ========================================================================
    tpu_core #(
        .SYSTOLIC_ARRAY_WIDTH(SYSTOLIC_ARRAY_WIDTH),
        .DATA_WIDTH_IN       (DATA_WIDTH_IN),
        .DATA_WIDTH_ACCUM    (DATA_WIDTH_ACCUM),
        .ADDR_WIDTH          (ADDR_WIDTH)
    ) core_inst (
        .clk(clk),
        .rst(rst),

        // Host 接口 (连接到顶层)
        .host_wr_addr_in(host_wr_addr_in),
        .host_wr_en_in  (host_wr_en_in),
        .host_wr_data_in(host_wr_data_in),

        // AXI Master 接口 (连接到顶层)
        .axim_rd_addr_in (axim_rd_addr_in),
        .axim_rd_en_in   (axim_rd_en_in),
        .axim_rd_data_out(axim_rd_data_out),

        // TPU Core 状态 (去往 cu_inst)
        .core_writeback_valid(core_writeback_valid),

        // TPU Core 控制 (来自 cu_inst)
        .ctrl_rd_addr_a     (ctrl_rd_addr_a),
        .ctrl_rd_en_a       (ctrl_rd_en_a),
        .ctrl_a_valid       (ctrl_a_valid),
        .ctrl_a_switch      (ctrl_a_switch),
        .ctrl_rd_addr_b     (ctrl_rd_addr_b),
        .ctrl_rd_en_b       (ctrl_rd_en_b),
        .ctrl_b_accept_w    (ctrl_b_accept_w),
        .ctrl_b_weight_index(ctrl_b_weight_index),
        .ctrl_rd_addr_c     (ctrl_rd_addr_c),
        .ctrl_rd_en_c       (ctrl_rd_en_c),
        .ctrl_wr_addr_d     (ctrl_wr_addr_d),
        .ctrl_row_mask      (ctrl_row_mask),
        .ctrl_col_mask      (ctrl_col_mask),
        .ctrl_vpu_mode      (ctrl_vpu_mode)
    );

endmodule
`timescale 1ns/1ps
`default_nettype none

/**
 * 模块名: tpu_top
 * 功能: TPU 顶层集成模块 (DUT for Verification)
 * 职责: 
 * 1. 实例化 tpu_controller_unified (指令调度)
 * 2. 实例化 tpu_core (数据通路)
 * 3. 连接内部所有的控制信号 (A/B/C/D Flow)
 * 4. 暴露 Host 接口用于测试激励
 */
module tpu_top #(
    parameter int ADDR_WIDTH           = 10,
    parameter int SYSTOLIC_ARRAY_WIDTH = 16,
    parameter int DATA_WIDTH_IN        = 8,
    parameter int DATA_WIDTH_ACCUM     = 32,
    parameter int CMD_DEPTH            = 8
)(
    input logic clk,
    input logic rst,

    // ========================================================================
    // 1. 配置接口 (模拟 AXI-Lite Write) -> 连接到 Controller
    // ========================================================================
    input logic        cfg_valid,      // Host 发送指令有效
    input logic [31:0] cfg_addr_a,     // A 矩阵基地址
    input logic [31:0] cfg_addr_b,     // B 矩阵基地址
    input logic [31:0] cfg_addr_c,     // C 矩阵基地址
    input logic [31:0] cfg_addr_d,     // D 矩阵基地址
    input logic [7:0]  cfg_m,          // 矩阵高度 M
    output logic       cfg_full,       // 指令队列满
    output logic       sys_idle,       // 系统空闲 (所有任务完成)

    // ========================================================================
    // 2. 数据写入接口 (模拟 AXI-Full Slave) -> 连接到 Input Buffer
    // ========================================================================
    input logic [ADDR_WIDTH-1:0]       host_wr_addr_in,
    input logic                        host_wr_en_in,
    input logic [DATA_WIDTH_ACCUM-1:0] host_wr_data_in [SYSTOLIC_ARRAY_WIDTH],

    // ========================================================================
    // 3. 数据读取接口 (模拟 AXI-Master Read) -> 连接到 Output Buffer
    // ========================================================================
    input logic [ADDR_WIDTH-1:0]        axim_rd_addr_in,
    input logic                         axim_rd_en_in,
    output logic [DATA_WIDTH_ACCUM-1:0] axim_rd_data_out [SYSTOLIC_ARRAY_WIDTH]
);

    // ========================================================================
    // 内部互联信号 (Controller -> Core)
    // ========================================================================
    
    // A-Flow
    logic [ADDR_WIDTH-1:0] w_ctrl_rd_addr_a;
    logic                  w_ctrl_rd_en_a;
    logic                  w_ctrl_a_valid;
    logic                  w_ctrl_a_switch;

    // B-Flow
    logic [ADDR_WIDTH-1:0] w_ctrl_rd_addr_b;
    logic                  w_ctrl_rd_en_b;
    logic                  w_ctrl_b_accept_w;
    logic [$clog2(SYSTOLIC_ARRAY_WIDTH)-1:0] w_ctrl_b_weight_index;

    // C-Flow
    logic [ADDR_WIDTH-1:0] w_ctrl_rd_addr_c;
    logic                  w_ctrl_rd_en_c;
    logic                  w_ctrl_c_valid;
    logic [2:0]            w_ctrl_vpu_mode;

    // D-Flow
    logic [ADDR_WIDTH-1:0] w_ctrl_wr_addr_d;
    logic [SYSTOLIC_ARRAY_WIDTH-1:0] w_ctrl_row_mask;
    logic [SYSTOLIC_ARRAY_WIDTH-1:0] w_ctrl_col_mask;

    // Feedback (Core -> Controller)
    logic w_core_writeback_valid;

    // ========================================================================
    // 实例 1: 统一控制器 (Brain)
    // ========================================================================
    tpu_controller_unified #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .SYSTOLIC_ARRAY_WIDTH(SYSTOLIC_ARRAY_WIDTH),
        .CMD_DEPTH(CMD_DEPTH)
    ) u_controller (
        .clk(clk),
        .rst(rst),
        
        // Host Config Inputs
        .cfg_valid(cfg_valid),
        .cfg_addr_a(cfg_addr_a),
        .cfg_addr_b(cfg_addr_b),
        .cfg_addr_c(cfg_addr_c),
        .cfg_addr_d(cfg_addr_d),
        .cfg_m(cfg_m),
        .cfg_full(cfg_full),
        .sys_idle(sys_idle),

        // Control Outputs (To Core)
        .ctrl_rd_addr_a(w_ctrl_rd_addr_a),
        .ctrl_rd_en_a(w_ctrl_rd_en_a),
        .ctrl_a_valid(w_ctrl_a_valid),
        .ctrl_a_switch(w_ctrl_a_switch),

        .ctrl_rd_addr_b(w_ctrl_rd_addr_b),
        .ctrl_rd_en_b(w_ctrl_rd_en_b),
        .ctrl_b_accept_w(w_ctrl_b_accept_w),
        .ctrl_b_weight_index(w_ctrl_b_weight_index),

        .ctrl_rd_addr_c(w_ctrl_rd_addr_c),
        .ctrl_rd_en_c(w_ctrl_rd_en_c),
        .ctrl_c_valid(w_ctrl_c_valid), // [Cite: 71]
        .ctrl_vpu_mode(w_ctrl_vpu_mode),

        .ctrl_wr_addr_d(w_ctrl_wr_addr_d),
        .ctrl_row_mask(w_ctrl_row_mask),
        .ctrl_col_mask(w_ctrl_col_mask),

        // Feedback Input
        .core_writeback_valid(w_core_writeback_valid)
    );

    // ========================================================================
    // 实例 2: 核心数据通路 (Body)
    // ========================================================================
    tpu_core #(
        .SYSTOLIC_ARRAY_WIDTH(SYSTOLIC_ARRAY_WIDTH),
        .DATA_WIDTH_IN(DATA_WIDTH_IN),
        .DATA_WIDTH_ACCUM(DATA_WIDTH_ACCUM),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_core (
        .clk(clk),
        .rst(rst),

        // Host Data Write (Input Buffer)
        .host_wr_addr_in(host_wr_addr_in),
        .host_wr_en_in(host_wr_en_in),
        .host_wr_data_in(host_wr_data_in),

        // AXI Master Read (Output Buffer)
        .axim_rd_addr_in(axim_rd_addr_in),
        .axim_rd_en_in(axim_rd_en_in),
        .axim_rd_data_out(axim_rd_data_out),

        // Control Inputs (From Controller)
        .ctrl_rd_addr_a(w_ctrl_rd_addr_a),
        .ctrl_rd_en_a(w_ctrl_rd_en_a),
        .ctrl_a_valid(w_ctrl_a_valid),
        .ctrl_a_switch(w_ctrl_a_switch),

        .ctrl_rd_addr_b(w_ctrl_rd_addr_b),
        .ctrl_rd_en_b(w_ctrl_rd_en_b),
        .ctrl_b_accept_w(w_ctrl_b_accept_w),
        .ctrl_b_weight_index(w_ctrl_b_weight_index),

        .ctrl_rd_addr_c(w_ctrl_rd_addr_c),
        .ctrl_rd_en_c(w_ctrl_rd_en_c),
        .ctrl_c_valid(w_ctrl_c_valid), // [Cite: 214]
        .ctrl_vpu_mode(w_ctrl_vpu_mode),

        .ctrl_wr_addr_d(w_ctrl_wr_addr_d),
        .ctrl_row_mask(w_ctrl_row_mask),
        .ctrl_col_mask(w_ctrl_col_mask),

        // Feedback Output
        .core_writeback_valid(w_core_writeback_valid)
    );

endmodule
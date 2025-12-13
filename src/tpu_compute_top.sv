`timescale 1ns/1ps
`default_nettype none

/**
 * 模块名: tpu_compute_top (Simplified Integration)
 * 功能: 仅集成 Control Unit 和 TPU Core
 * 用途: 
 * - 绕过 APB/AXI 总线协议，直接测试核心计算逻辑。
 * - 暴露 SRAM 读写端口，方便 Testbench 直接灌入数据和读取结果。
 */
module tpu_compute_top #(
    parameter int SYSTOLIC_ARRAY_WIDTH = 16,
    parameter int DATA_WIDTH_IN        = 8,
    parameter int DATA_WIDTH_ACCUM     = 32,
    parameter int ADDR_WIDTH           = 10
)(
    input logic clk,
    input logic rst_n, // Active Low Reset (外部通常是低电平复位)

    // ========================================================================
    // 1. 指令接口 (Command Interface)
    // 直接连接到 Control Unit
    // ========================================================================
    input  logic        cmd_valid,
    input  logic [63:0] cmd_data,
    output logic        cmd_ready,
    output logic        busy,
    output logic        done_irq,

    // ========================================================================
    // 2. 数据加载接口 (SRAM Write Interface)
    // 用于预加载 Input Buffer (A/B/C 矩阵)
    // ========================================================================
    input  logic [ADDR_WIDTH-1:0]       host_wr_addr,
    input  logic                        host_wr_en,
    input  logic [DATA_WIDTH_ACCUM-1:0] host_wr_data [SYSTOLIC_ARRAY_WIDTH],

    // ========================================================================
    // 3. 结果读取接口 (SRAM Read Interface)
    // 用于从 Output Buffer 读取结果 (D 矩阵)
    // ========================================================================
    input  logic [ADDR_WIDTH-1:0]       host_rd_addr,
    input  logic                        host_rd_en,
    output logic signed [DATA_WIDTH_ACCUM-1:0] host_rd_data [SYSTOLIC_ARRAY_WIDTH]
);

    localparam W = SYSTOLIC_ARRAY_WIDTH;

    // 内部复位信号 (子模块使用高电平复位)
    logic rst;
    assign rst = ~rst_n; 

    // ========================================================================
    // 内部互联信号 (Interconnects)
    // ========================================================================
    
    // A-Flow
    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_a;
    logic                  ctrl_rd_en_a;
    logic                  ctrl_a_valid;
    logic                  ctrl_a_switch;
    logic                  ctrl_psum_valid; // [重要] Psum Valid 链路
    
    // B-Flow
    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_b;
    logic                  ctrl_rd_en_b;
    logic                  ctrl_b_accept_w;
    logic [$clog2(W)-1:0]  ctrl_b_weight_index;
    
    // C-Flow
    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_c;
    logic                  ctrl_rd_en_c;
    logic                  ctrl_c_valid;
    logic [2:0]            ctrl_vpu_mode;
    
    // D-Flow & Feedback
    logic [ADDR_WIDTH-1:0] ctrl_wr_addr_d;
    logic [W-1:0]          ctrl_row_mask;
    logic [W-1:0]          ctrl_col_mask;
    logic                  core_writeback_valid;

    // ========================================================================
    // 1. Control Unit 实例化
    // ========================================================================
    control_unit #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .SYSTOLIC_ARRAY_WIDTH(W)
    ) u_cu (
        .clk(clk),
        .rst(rst),

        // Host Command Interface
        .cmd_valid(cmd_valid),
        .cmd_data(cmd_data),
        .cmd_ready(cmd_ready),
        .busy(busy),
        .done_irq(done_irq),

        // A-Flow Controls
        .ctrl_rd_addr_a(ctrl_rd_addr_a), 
        .ctrl_rd_en_a(ctrl_rd_en_a),
        .ctrl_a_valid(ctrl_a_valid),     
        .ctrl_a_switch(ctrl_a_switch),
        .ctrl_psum_valid(ctrl_psum_valid), // [Connected]

        // B-Flow Controls
        .ctrl_rd_addr_b(ctrl_rd_addr_b), 
        .ctrl_rd_en_b(ctrl_rd_en_b),
        .ctrl_b_accept_w(ctrl_b_accept_w), 
        .ctrl_b_weight_index(ctrl_b_weight_index),

        // C-Flow Controls
        .ctrl_rd_addr_c(ctrl_rd_addr_c), 
        .ctrl_rd_en_c(ctrl_rd_en_c),
        .ctrl_c_valid(ctrl_c_valid),     
        .ctrl_vpu_mode(ctrl_vpu_mode),

        // D-Flow & Feedback
        .core_writeback_valid(core_writeback_valid),
        .ctrl_wr_addr_d(ctrl_wr_addr_d),
        
        // Masks
        .ctrl_row_mask(ctrl_row_mask),
        .ctrl_col_mask(ctrl_col_mask)
    );

    // ========================================================================
    // 2. TPU Core 实例化
    // ========================================================================
    tpu_core #(
        .SYSTOLIC_ARRAY_WIDTH(W),
        .DATA_WIDTH_IN(DATA_WIDTH_IN),
        .DATA_WIDTH_ACCUM(DATA_WIDTH_ACCUM),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_core (
        .clk(clk),
        .rst(rst),

        // SRAM Host Write (Direct Access)
        .host_wr_addr_in(host_wr_addr),
        .host_wr_en_in(host_wr_en),
        .host_wr_data_in(host_wr_data),

        // SRAM Host Read (Direct Access)
        .axim_rd_addr_in(host_rd_addr),
        .axim_rd_en_in(host_rd_en),
        .axim_rd_data_out(host_rd_data), // Signed output [cite: 402]

        // A-Flow Controls
        .ctrl_rd_addr_a(ctrl_rd_addr_a), 
        .ctrl_rd_en_a(ctrl_rd_en_a),
        .ctrl_a_valid(ctrl_a_valid),     
        .ctrl_a_switch(ctrl_a_switch),
        .ctrl_psum_valid(ctrl_psum_valid), // [Connected]

        // B-Flow Controls
        .ctrl_rd_addr_b(ctrl_rd_addr_b), 
        .ctrl_rd_en_b(ctrl_rd_en_b),
        .ctrl_b_accept_w(ctrl_b_accept_w), 
        .ctrl_b_weight_index(ctrl_b_weight_index),

        // C-Flow Controls
        .ctrl_rd_addr_c(ctrl_rd_addr_c), 
        .ctrl_rd_en_c(ctrl_rd_en_c),
        .ctrl_c_valid(ctrl_c_valid),     
        .ctrl_vpu_mode(ctrl_vpu_mode),

        // D-Flow & Feedback
        .ctrl_wr_addr_d(ctrl_wr_addr_d),
        .core_writeback_valid(core_writeback_valid),
        
        // Masks
        .ctrl_row_mask(ctrl_row_mask), 
        .ctrl_col_mask(ctrl_col_mask)
    );

endmodule
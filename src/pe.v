`timescale 1ns/1ps
`default_nettype none

// 修正版 Verilog PE 模块
// 解决了 'weight_reg_active' 的多重驱动问题
module pe (
    input wire clk,
    input wire rst,

    // --- North wires ---
    input wire signed [31:0] pe_psum_in,
    input wire signed [7:0]  pe_weight_in,
    input wire               pe_accept_w_in, 
    
    // --- West wires ---
    input wire signed [7:0]  pe_input_in,
    input wire               pe_valid_in, 
    input wire               pe_switch_in, 
    
    input wire               pe_enabled,

    // --- South wires ---
    output reg signed [31:0] pe_psum_out,
    output reg signed [7:0]  pe_weight_out,

    // --- East wires ---
    output reg signed [7:0]  pe_input_out,
    output reg               pe_valid_out,
    output reg               pe_switch_out
);

    // 内部信号
    wire signed [15:0] mult_out;
    wire signed [31:0] mac_out;
    
    // 寄存器 (由下面的 *单个* always 块驱动)
    reg  signed [7:0]  weight_reg_active;  // 前景寄存器
    reg  signed [7:0]  weight_reg_inactive;// 背景寄存器

    // --- 运算逻辑 (组合) ---
    assign mult_out = pe_input_in * weight_reg_active;
    assign mac_out = mult_out + pe_psum_in;

    // --- 修正: 移除了驱动 'weight_reg_active' 的 always @(*) 块 ---

    // --- 时序逻辑: 所有寄存器更新 ---
    // 所有的 reg 变量现在都只由这一个 always 块驱动
    always @(posedge clk or posedge rst) begin
        if (rst || !pe_enabled) begin
            // 复位所有寄存器
            pe_input_out      <= 8'b0;
            weight_reg_active <= 8'b0; // <-- 在复位时驱动
            weight_reg_inactive <= 8'b0;
            pe_valid_out      <= 1'b0;
            pe_weight_out     <= 8'b0;
            pe_switch_out     <= 1'b0;
            pe_psum_out       <= 32'b0; 
            
        end else begin
            // 默认行为 (非复位状态)
            pe_valid_out  <= pe_valid_in;
            pe_switch_out <= pe_switch_in;

            // --- 权重寄存器逻辑 ---

            // 1. 更新 Inactive (背景) 寄存器
            if (pe_accept_w_in) begin
                weight_reg_inactive <= pe_weight_in;
                pe_weight_out       <= pe_weight_in;
            end else begin
                pe_weight_out <= 8'b0;
            end

            // 2. 更新 Active (前景) 寄存器
            // 修正: 'pe_switch_in' 逻辑被移到这里
            if (pe_switch_in) begin
                weight_reg_active <= weight_reg_inactive; // <-- 在时钟沿驱动
            end
            // 注意: 如果 'pe_switch_in' 为 0, 'weight_reg_active' 保持其现有值

            // --- 数据和部分和(psum)更新 ---
            if (pe_valid_in) begin
                pe_input_out <= pe_input_in;
                pe_psum_out  <= mac_out;
            end else begin
                // 当 valid_in 为 0 时, pe_valid_out 也为 0
                pe_psum_out <= 32'b0; 
            end
        end
    end

endmodule
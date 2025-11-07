`timescale 1ns/1ps
`default_nettype none

// Verilog (非 SystemVerilog) 版本的 PE 模块
// 针对 int8 输入 (A, B) 和 int32 累加 (C, D) 进行了修改
module pe (
    input wire clk,
    input wire rst,

    // --- North wires (来自上方PE或UB) ---
    // 修改: 32位有符号累加输入
    input wire signed [31:0] pe_psum_in,
    // 修改: 8位有符号权重输入 (矩阵B)
    input wire signed [7:0]  pe_weight_in,
    input wire               pe_accept_w_in, 
    
    // --- West wires (来自左侧PE或UB) ---
    // 修改: 8位有符号数据输入 (矩阵A)
    input wire signed [7:0]  pe_input_in,
    input wire               pe_valid_in, 
    input wire               pe_switch_in, 
    
    // 使能信号
    input wire               pe_enabled,

    // --- South wires (去往下方PE) ---
    // 修改: 32位有符号累加输出
    output reg signed [31:0] pe_psum_out,
    // 修改: 8位有符号权重输出
    output reg signed [7:0]  pe_weight_out,

    // --- East wires (去往右侧PE) ---
    // 修改: 8位有符号数据输出
    output reg signed [7:0]  pe_input_out,
    output reg               pe_valid_out,
    output reg               pe_switch_out
);

    // 内部信号定义
    // 修改: 8b * 8b = 16b
    wire signed [15:0] mult_out;
    // 修改: 16b + 32b = 32b
    wire signed [31:0] mac_out;
    // 修改: 8位权重寄存器
    reg  signed [7:0]  weight_reg_active;  // 前景寄存器 [cite: 60]
    // 修改: 8位权重寄存器
    reg  signed [7:0]  weight_reg_inactive;// 背景寄存器 

    // --- 运算逻辑 ---
    // 移除: fxp_mul 实例 
    // 替换为: Verilog 原生整数乘法
    // (8b * 8b = 16b)
    assign mult_out = pe_input_in * weight_reg_active;
            
    // 移除: fxp_add 实例 
    // 替换为: Verilog 原生整数加法
    // (16b + 32b = 32b), Verilog 会自动进行符号位扩展
    assign mac_out = mult_out + pe_psum_in;

    // --- 组合逻辑: 权重切换 ---
    // (原  always_comb)
    always @(*) begin
        // Verilog-2001 不支持 always_comb 中的自动推断
        // 为了安全，我们假设 weight_reg_active 保持不变，除非切换
        weight_reg_active = weight_reg_active;
        if (pe_switch_in) begin
            weight_reg_active = weight_reg_inactive;
        end
    end

    // --- 时序逻辑: 寄存器更新 ---
    // (原  always_ff)
    always @(posedge clk or posedge rst) begin
        if (rst || !pe_enabled) begin
            // 修改: 更新所有复位值的数据宽度
            pe_input_out      <= 8'b0;
            weight_reg_active <= 8'b0;
            weight_reg_inactive <= 8'b0;
            pe_valid_out      <= 1'b0;
            pe_weight_out     <= 8'b0;
            pe_switch_out     <= 1'b0;
            // [cite: 71] (原 16'b0)
            pe_psum_out       <= 32'b0; 
        end else begin
            pe_valid_out  <= pe_valid_in;
            pe_switch_out <= pe_switch_in;

            // 权重寄存器更新 [cite: 67]
            if (pe_accept_w_in) begin
                weight_reg_inactive <= pe_weight_in;
                pe_weight_out       <= pe_weight_in;
            end else begin
                // [cite: 68] (原 0，明确位宽)
                pe_weight_out <= 8'b0;
            end

            // 数据和部分和(psum)更新
            if (pe_valid_in) begin
                pe_input_out <= pe_input_in;
                // [cite: 70]
                pe_psum_out  <= mac_out;
            end else begin
                // 当 valid_in 为 0 时, pe_valid_out 也为 0
                // [cite: 71] (原 16'b0)
                pe_psum_out <= 32'b0; 
            end
        end
    end

endmodule
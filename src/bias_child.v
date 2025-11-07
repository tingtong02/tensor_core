`timescale 1ns/1ps
`default_nettype none

// Verilog (非 SystemVerilog) 版本的 bias_child 模块
// 针对 int32 输入 (A*B 的结果 和 C) 和 int32 输出 (D) 进行了修改
module bias_child (
    input wire clk,
    input wire rst,

    // 修改: 32位有符号偏置输入 (矩阵 C)
    input wire signed [31:0] bias_scalar_in, 
    output reg               bias_Z_valid_out, 

    // 修改: 32位有符号数据输入 (来自 systolic array, A*B 的结果)
    input wire signed [31:0] bias_sys_data_in, 
    input wire               bias_sys_valid_in,

    // 修改: 32位有符号数据输出 (最终结果 D = A*B + C)
    output reg signed [31:0] bias_z_data_out
);

    // 内部信号
    // 修改: 32位加法结果
    wire signed [31:0] z_pre_activation;

    // 移除: fxp_add add_inst (...) 
    // 替换为: Verilog 原生整数加法
    assign z_pre_activation = bias_sys_data_in + bias_scalar_in;
    
    // (原始注释 [cite: 78, 79] 保留)
    // TODO: we only switch bias values for EACH layer!!!!
    // maybe change logic herer

    // 时序逻辑
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            bias_Z_valid_out <= 1'b0;
            // 修改: 复位值为 32'b0
            bias_z_data_out  <= 32'b0; 
        end else begin
            if (bias_sys_valid_in) begin // valid data coming through
                bias_Z_valid_out <= 1'b1;
                // 输出加法结果
                bias_z_data_out  <= z_pre_activation; 
            end else begin
                bias_Z_valid_out <= 1'b0; 
                // 修改: 复位值为 32'b0
                bias_z_data_out  <= 32'b0; 
            end
        end
    end

endmodule
`timescale 1ns/1ps
`default_nettype none

/**
 * VPU 子单元: Bias Child
 * 功能: 执行 D = E + C (矩阵元素加法)
 * 端口命名: 沿用 reference design 
 */
module bias_child #(
    parameter int DATA_WIDTH = 32 // 默认适配 Systolic Psum (32-bit)
)(
    input logic clk,
    input logic rst,

    // --- 输入: C (Bias Scalar, 来自 UB) ---
    input logic signed [DATA_WIDTH-1:0] bias_scalar_in, 

    // --- 输入: E (Systolic Data, 来自 Systolic Array) ---
    input wire signed [DATA_WIDTH-1:0] bias_sys_data_in, 
    input wire                         bias_sys_valid_in, 

    // --- 输出: D (Result, 去往下一级或 UB) ---
    output logic signed [DATA_WIDTH-1:0] bias_z_data_out,
    output logic                         bias_Z_valid_out 
);

    // 内部计算线网
    logic signed [DATA_WIDTH-1:0] z_pre_activation;

    // 加法逻辑 [cite: 166]
    // (在高性能设计中，这里通常建议加一个 Saturation 逻辑防止溢出翻转)
    assign z_pre_activation = bias_sys_data_in + bias_scalar_in;

    // 时序逻辑: 流水线寄存器
    // 只有当输入有效 (bias_sys_valid_in == 1) 时，输出才有效 
    always_ff @(posedge clk) begin
        if (rst) begin
            bias_z_data_out  <= '0;
            bias_Z_valid_out <= 1'b0; // [cite: 168]
        end else begin
            if (bias_sys_valid_in) begin
                // 有效数据到达: 锁存计算结果 
                bias_z_data_out  <= z_pre_activation;
                bias_Z_valid_out <= 1'b1;
            end else begin
                // 无效数据 (气泡): 输出无效 [cite: 171]
                // 保持 0 或保持上一拍 (这里置 0 以保持波形整洁)
                bias_z_data_out  <= '0;
                bias_Z_valid_out <= 1'b0;
            end
        end
    end

endmodule
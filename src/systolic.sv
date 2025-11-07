`timescale 1ns/1ps
`default_nettype none

// 修改: 参数化 $N x N$ 阵列, 默认 16x16
module systolic #(
    parameter int SYSTOLIC_ARRAY_WIDTH = 16
)(
    input logic clk,
    input logic rst,

    // --- West Inputs (Data A) ---
    // 修改: 端口数组化, int8
    input logic signed [ 7:0] sys_data_in   [SYSTOLIC_ARRAY_WIDTH-1:0],
    input logic               sys_valid_in  [SYSTOLIC_ARRAY_WIDTH-1:0],

    // --- North Inputs (Data B) ---
    // 修改: 端口数组化, int8
    input logic signed [ 7:0] sys_weight_in [SYSTOLIC_ARRAY_WIDTH-1:0],
    input logic               sys_accept_w  [SYSTOLIC_ARRAY_WIDTH-1:0],

    // --- South Outputs (Data D) ---
    // 修改: 端口数组化, int32
    output logic signed [31:0] sys_data_out  [SYSTOLIC_ARRAY_WIDTH-1:0],
    output logic               sys_valid_out [SYSTOLIC_ARRAY_WIDTH-1:0], // 来自最后一行的 pe_valid_out

    // --- Control Signals ---
    // 修改: sys_switch_in 变为数组, 对应每行
    input logic               sys_switch_in [SYSTOLIC_ARRAY_WIDTH-1:0], 
    input logic [15:0]        ub_rd_col_size_in,
    input logic               ub_rd_col_size_valid_in
);

    // --- 内部连线网格 ---
    // 修改: 移除所有 pe_..._11, pe_..._12 等硬编码线网 [cite: 19-25]
    // 替换为 2D 数组
    logic signed [ 7:0] pe_input_out  [SYSTOLIC_ARRAY_WIDTH-1:0][SYSTOLIC_ARRAY_WIDTH-1:0];
    logic signed [ 7:0] pe_weight_out [SYSTOLIC_ARRAY_WIDTH-1:0][SYSTOLIC_ARRAY_WIDTH-1:0];
    logic signed [31:0] pe_psum_out   [SYSTOLIC_ARRAY_WIDTH-1:0][SYSTOLIC_ARRAY_WIDTH-1:0];
    logic               pe_valid_out  [SYSTOLIC_ARRAY_WIDTH-1:0][SYSTOLIC_ARRAY_WIDTH-1:0];
    logic               pe_switch_out [SYSTOLIC_ARRAY_WIDTH-1:0][SYSTOLIC_ARRAY_WIDTH-1:0];

    // --- PE 使能控制 ---
    // 修改: 位宽与阵列宽度匹配
    logic [SYSTOLIC_ARRAY_WIDTH-1:0] pe_enabled;


    // --- 动态生成 PE 阵列 ---
    // 移除所有硬编码的 pe11, pe12, pe21, pe22 实例 
    genvar i, j;
    generate
        for (i = 0; i < SYSTOLIC_ARRAY_WIDTH; i++) begin : row_gen
            for (j = 0; j < SYSTOLIC_ARRAY_WIDTH; j++) begin : col_gen
                
                pe pe_inst (
                    .clk(clk),
                    .rst(rst),
                    
                    // PE使能 (来自底部的 pe_enabled 逻辑)
                    .pe_enabled(pe_enabled[j]),

                    // --- North Wires ---
                    // 1. psum (来自上方PE，或 0)
                    .pe_psum_in( (i == 0) ? 32'b0 : pe_psum_out[i-1][j] ),
                    // 2. weight (来自上方PE，或 阵列输入)
                    .pe_weight_in( (i == 0) ? sys_weight_in[j] : pe_weight_out[i-1][j] ),
                    // 3. accept_w (来自阵列输入, 广播到该列)
                    .pe_accept_w_in( sys_accept_w[j] ),

                    // --- West Wires ---
                    // 1. input (来自左侧PE，或 阵列输入)
                    .pe_input_in( (j == 0) ? sys_data_in[i] : pe_input_out[i][j-1] ),
                    // 2. valid (来自左侧PE，或 阵列输入)
                    .pe_valid_in( (j == 0) ? sys_valid_in[i] : pe_valid_out[i][j-1] ),
                    // 3. switch (来自左侧PE，或 阵列输入)
                    .pe_switch_in( (j == 0) ? sys_switch_in[i] : pe_switch_out[i][j-1] ),

                    // --- South Wires (Outputs) ---
                    .pe_psum_out(pe_psum_out[i][j]),
                    .pe_weight_out(pe_weight_out[i][j]),

                    // --- East Wires (Outputs) ---
                    .pe_input_out(pe_input_out[i][j]),
                    .pe_valid_out(pe_valid_out[i][j]),
                    .pe_switch_out(pe_switch_out[i][j])
                );
                
            end
        end
    endgenerate

    // --- 模块输出连接 ---
    // 最终的 psum 结果来自阵列的最后一行
    // 最终的 valid 信号也来自阵列的最后一行 (从左向右传播)
    generate
        for (j = 0; j < SYSTOLIC_ARRAY_WIDTH; j++) begin : output_gen
            assign sys_data_out[j]  = pe_psum_out[SYSTOLIC_ARRAY_WIDTH-1][j];
            assign sys_valid_out[j] = pe_valid_out[SYSTOLIC_ARRAY_WIDTH-1][j];
        end
    endgenerate


    // --- PE 使能逻辑 ---
    // (与原代码  相同, 仅更新了 pe_enabled 位宽)
    always_ff @(posedge clk or posedge rst) begin
        if(rst) begin
            pe_enabled <= '0;
        end else begin
            if(ub_rd_col_size_valid_in) begin
                // (1 << N) - 1 会生成 N 个 '1'
                // 例如: N=4, (1 << 4) - 1 = 10000 - 1 = 1111
                pe_enabled <= (1 << ub_rd_col_size_in) - 1;
            end
            // 如果 valid 为 0, pe_enabled 保持不变
        end
    end

endmodule
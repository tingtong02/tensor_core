`timescale 1ns/1ps
`default_nettype none

/**
 * 模块名: vpu (Vector Processing Unit) - Modified
 * 功能: 执行 D = E + C 等后处理操作
 * 修改逻辑:
 * - 引入 vpu_bias_valid_in 确保数据对齐安全性。
 * - 实现了 Valid 信号的“与”操作，防止无效数据污染结果。
 */
module vpu #(
    parameter int VPU_WIDTH     = 16,
    parameter int DATA_WIDTH_IN = 32
)(
    input logic clk,
    input logic rst,

    // --- 控制信号 ---
    // [0]: Enable Bias Add (1=Enable, 0=Bypass)
    input logic [2:0] vpu_mode, 

    // --- 数据输入 (来自 Systolic Array) ---
    input logic signed [DATA_WIDTH_IN-1:0] vpu_sys_data_in  [VPU_WIDTH],
    input logic                            vpu_sys_valid_in [VPU_WIDTH],

    // --- Bias 输入 (来自 Input Buffer/Skew Logic) ---
    input logic signed [DATA_WIDTH_IN-1:0] vpu_bias_data_in [VPU_WIDTH],
    input logic                            vpu_bias_valid_in [VPU_WIDTH], // [NEW] 新增 Bias 有效性输入

    // --- 数据输出 (去往 De-skew Logic) ---
    output logic signed [DATA_WIDTH_IN-1:0] vpu_data_out  [VPU_WIDTH],
    output logic                            vpu_valid_out [VPU_WIDTH]
);

    genvar j;
    generate
        for (j = 0; j < VPU_WIDTH; j++) begin : vpu_lane_gen
            
            // --- 内部信号声明 ---
            logic signed [DATA_WIDTH_IN-1:0] bias_result_data;
            logic                            bias_result_valid;

            // ============================================================
            // 1. 安全校验逻辑 (Valid Gating)
            // ============================================================
            // 核心修改: 创建一个合并的 Valid 信号。
            // 逻辑: 只有当 脉动阵列输出(Psum) 和 偏置输入(Bias) 在同一时刻都有效时，
            //       我们才将此视为有效的计算请求。
            // 效果: 如果 Control Unit 的时序稍有偏差（例如 Bias 晚到一拍），
            //       combined_valid_in 将为 0，bias_child 会输出无效 (0)，
            //       从而保护 Output Buffer 不被写入错误的计算结果。
            logic combined_valid_in;
            assign combined_valid_in = vpu_sys_valid_in[j] && vpu_bias_valid_in[j];

            // ============================================================
            // 2. Bias 加法单元 (Stage 1)
            // ============================================================
            bias_child #(
                .DATA_WIDTH(DATA_WIDTH_IN)
            ) bias_inst (
                .clk(clk),
                .rst(rst),
                
                // 数据端口
                .bias_sys_data_in(vpu_sys_data_in[j]),   // E 矩阵元素
                .bias_scalar_in(vpu_bias_data_in[j]),    // C 矩阵元素

                // 控制端口 [关键修改]
                // 将合并后的 Valid 信号传入子模块。
                // 子模块内部逻辑是: always_ff @(posedge clk) if (valid_in) valid_out <= 1;
                // 这意味着只有两者都有效，下一拍的输出才会有效。
                .bias_sys_valid_in(combined_valid_in),   

                // 输出端口
                .bias_z_data_out(bias_result_data),      // D 矩阵元素 (Stage 1结果)
                .bias_Z_valid_out(bias_result_valid)
            );

            // ============================================================
            // 3. 输出分配
            // ============================================================
            // 可以在这里添加额外的 MUX 逻辑处理 vpu_mode (如 ReLU)
            // 目前直接输出 Bias 加法结果
            assign vpu_data_out[j]  = bias_result_data;
            assign vpu_valid_out[j] = bias_result_valid;

        end
    endgenerate

endmodule
`timescale 1ns/1ps
`default_nettype none

/**
 * 向量处理单元 (VPU) Top Module - Enhanced
 * 功能: 后处理流水线，支持模式选择
 * * vpu_mode 定义 (Bitmask):
 * [0]: Enable Bias Add (1=Enable, 0=Bypass)
 * [1]: Enable ReLU    (1=Enable, 0=Bypass) [预留]
 * [2]: Enable Quant   (1=Enable, 0=Bypass) [预留]
 */

/*
!如果在时钟上升沿到来时，这两个数据没有同时出现在端口上
例如 $E$ 到了，但 $C$ 还没到，或者 $C$ 早到了
!加法器就会计算出错误的结果
$E + \text{Garbage}$ 或 $\text{Garbage} + C$
!由于 VPU 内部没有设计 FIFO（先进先出队列） 来缓冲或对齐数据，这种同步责任完全转移给了外部控制器。
!如果更改pe为2 stage，那么这里将会很麻烦，对于控制器时序要求很高
*/

module vpu #(
    parameter int VPU_WIDTH     = 16,
    parameter int DATA_WIDTH_IN = 32
)(
    input logic clk,
    input logic rst,

    // --- 控制信号 ---
    // 用于选择计算模式
    input logic [2:0] vpu_mode, 

    // --- 数据输入 ---
    input logic signed [DATA_WIDTH_IN-1:0] vpu_sys_data_in  [VPU_WIDTH],
    input logic                            vpu_sys_valid_in [VPU_WIDTH],

    // --- Bias 输入 (UB) ---
    input logic signed [DATA_WIDTH_IN-1:0] vpu_bias_data_in [VPU_WIDTH],

    // --- 数据输出 ---
    output logic signed [DATA_WIDTH_IN-1:0] vpu_data_out  [VPU_WIDTH],
    output logic                            vpu_valid_out [VPU_WIDTH]
);

    // --- 流水线级间信号 ---
    // Stage 1 (Bias) 的原始输出
    logic signed [DATA_WIDTH_IN-1:0] s1_bias_result [VPU_WIDTH];
    logic                            s1_bias_valid  [VPU_WIDTH];

    // // Stage 1 最终输出 (经过 MUX 选择后)
    // logic signed [DATA_WIDTH_IN-1:0] s1_final_data  [VPU_WIDTH];
    // logic                            s1_final_valid [VPU_WIDTH];

    genvar j;
    generate
        for (j = 0; j < VPU_WIDTH; j++) begin : vpu_lane_gen
            
            // ============================================================
            // STAGE 1: Bias Addition Unit
            // ============================================================
            bias_child #(
                .DATA_WIDTH(DATA_WIDTH_IN)
            ) bias_inst (
                .clk(clk),
                .rst(rst),
                .bias_sys_data_in(vpu_sys_data_in[j]),
                .bias_sys_valid_in(vpu_sys_valid_in[j]),
                .bias_scalar_in(vpu_bias_data_in[j]),
                .bias_z_data_out(s1_bias_result[j]),
                .bias_Z_valid_out(s1_bias_valid[j])
            );

            // ============================================================
            // STAGE 1 MUX: 选择逻辑 (Bypass Logic)
            // ============================================================
            // 如果 vpu_mode[0] == 1, 选择 Bias 计算结果
            // 如果 vpu_mode[0] == 0, 直接旁路输入数据 (不做加法)
            // 注意：如果选择旁路，我们需要手动对齐时延(Delay)，
            // 或者在这个简单设计中，我们可以接受旁路路径少一拍延迟。
            // 但在高性能设计中，通常建议旁路路径也要经过一个寄存器以保持对齐。
            
            // 这里为了保持流水线整洁，最简单的做法是：
            // 无论是否 bypass，数据都流经 bias_child，
            // 所谓的 "Bypass" 可以在软件层面通过将 Bias 输入置为 0 来实现。
            
            // 但如果您坚持要硬件 MUX 选择 (例如为了省功耗或特殊路由):
            /*
            assign s1_final_data[j] = (vpu_mode[0]) ? s1_bias_result[j] : vpu_sys_data_in[j];
            assign s1_final_valid[j] = (vpu_mode[0]) ? s1_bias_valid[j] : vpu_sys_valid_in[j];
            */

            // **架构师建议：**
            // 对于 "加法" 这种操作，硬件 MUX 其实不如 **"软件置零"** 高效。
            // 如果不想加 Bias，只需让 UB 送入的 `vpu_bias_data_in` 全为 0 即可。
            // 这样可以省去 MUX 的延迟和面积，且流水线极其规整。
            
            // 但是，对于 **ReLU** 这种非线性操作，您**必须**要有 MUX。
            // 下面演示 ReLU 的 MUX 写法：

            // ============================================================
            // [预留] STAGE 2: ReLU
            // ============================================================
            /*
            logic signed [31:0] relu_raw_out;
            logic relu_raw_valid;

            relu_child relu_inst (..., .in(s1_bias_result[j]), .out(relu_raw_out)...);

            // MUX:
            // vpu_mode[1]==1 : 使用 ReLU 结果
            // vpu_mode[1]==0 : 使用 Stage 1 结果 (直通)
            assign s2_final_data[j] = (vpu_mode[1]) ? relu_raw_out : s1_bias_result[j];
            */

            // ============================================================
            // FINAL OUTPUT
            // ============================================================
            // 目前直接输出 Stage 1 结果
            assign vpu_data_out[j]  = s1_bias_result[j];
            assign vpu_valid_out[j] = s1_bias_valid[j];

        end
    endgenerate

endmodule
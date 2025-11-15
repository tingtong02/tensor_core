`timescale 1ns/1ps
`default_nettype none

/**
 * 模块名: tpu_core
 * 功能: TPU 数据通路核心集成
 * 包含: Unified Buffer + Skew Logic + Systolic Array + VPU + De-skew Logic
 * 职责: 负责数据的流动、时序对齐和运算，不包含复杂的 FSM 控制逻辑。
 */
module tpu_core #(
    parameter int SYSTOLIC_ARRAY_WIDTH = 16,
    parameter int DATA_WIDTH_IN        = 8,   // Systolic 输入位宽 (int8)
    parameter int DATA_WIDTH_ACCUM     = 32,  // 累加/VPU/UB 位宽 (int32)
    parameter int ADDR_WIDTH           = 10   // UB 地址深度
)(
    input logic clk,
    input logic rst,

    // ========================================================================
    // 1. Host 接口 (用于写入 A/B/C 矩阵到 UB)
    // ========================================================================
    input logic [ADDR_WIDTH-1:0] host_wr_addr,
    input logic                  host_wr_en,
    input logic [DATA_WIDTH_ACCUM-1:0] host_wr_data [SYSTOLIC_ARRAY_WIDTH],

    // ========================================================================
    // 2. Control Unit 接口 (用于驱动数据流动)
    // ========================================================================
    
    // --- A-Flow (权重加载) 控制 ---
    input logic [ADDR_WIDTH-1:0] ctrl_rd_addr_a,
    input logic                  ctrl_rd_en_a,
    input logic                  ctrl_accept_w,     // 全局 Accept 信号
    input logic [$clog2(SYSTOLIC_ARRAY_WIDTH)-1:0] ctrl_weight_index, // 全局 Index

    // --- B-Flow (数据输入) 控制 ---
    input logic [ADDR_WIDTH-1:0] ctrl_rd_addr_b,
    input logic                  ctrl_rd_en_b,
    input logic                  ctrl_sys_valid,    // 全局 Valid 信号
    input logic                  ctrl_sys_switch,   // 全局 Switch 信号

    // --- C-Flow (Bias) & VPU 控制 ---
    input logic [ADDR_WIDTH-1:0] ctrl_rd_addr_c,
    input logic                  ctrl_rd_en_c,
    input logic [2:0]            ctrl_vpu_mode,

    // --- 回写 (Writeback) 控制 ---
    // VPU 计算结果写回 UB 的地址 (由 Controller 提供)
    input logic [ADDR_WIDTH-1:0] ctrl_wr_addr_d, 

    // --- 精确使能掩码 ---
    input logic [SYSTOLIC_ARRAY_WIDTH-1:0] ctrl_row_mask,
    input logic [SYSTOLIC_ARRAY_WIDTH-1:0] ctrl_col_mask,

    // ========================================================================
    // 3. 调试/状态输出
    // ========================================================================
    output logic core_busy, // (可选)
    output logic writeback_done // 当一整行数据写回 UB 时脉冲
);

    localparam W = SYSTOLIC_ARRAY_WIDTH;

    // ========================================================================
    // 内部连线定义
    // ========================================================================
    
    // UB 读出数据
    logic [DATA_WIDTH_ACCUM-1:0] ub_rd_a [W]; // 32-bit
    logic [DATA_WIDTH_ACCUM-1:0] ub_rd_b [W]; // 32-bit
    logic [DATA_WIDTH_ACCUM-1:0] ub_rd_c [W]; // 32-bit

    // UB 写入仲裁
    logic [ADDR_WIDTH-1:0]       ub_final_wr_addr;
    logic                        ub_final_wr_en;
    logic [DATA_WIDTH_ACCUM-1:0] ub_final_wr_data [W];

    // 截断后的数据 (给 Systolic)
    logic signed [DATA_WIDTH_IN-1:0] sys_in_a_raw [W];
    logic signed [DATA_WIDTH_IN-1:0] sys_in_b_raw [W];

    // 经过 Skew (延迟) 后的数据 (给 Systolic)
    logic signed [DATA_WIDTH_IN-1:0] sys_in_a_skewed [W];
    logic        [$clog2(W)-1:0]     sys_idx_skewed  [W];
    logic                            sys_acc_skewed  [W];

    logic signed [DATA_WIDTH_IN-1:0] sys_in_b_skewed [W];
    logic                            sys_val_skewed  [W];
    logic                            sys_sw_skewed   [W];

    // Systolic 输出
    logic signed [DATA_WIDTH_ACCUM-1:0] sys_out_data [W];
    logic                               sys_out_valid [W];

    // VPU 输出 (未对齐)
    logic signed [DATA_WIDTH_ACCUM-1:0] vpu_out_data [W];
    logic                               vpu_out_valid [W];

    // VPU 输出 (经过 De-skew 对齐后)
    logic signed [DATA_WIDTH_ACCUM-1:0] aligned_wr_data [W];
    logic                               aligned_wr_valid; // 所有列都对齐后的 Valid

    // ========================================================================
    // 模块 1: Unified Buffer
    // ========================================================================
    
    // 写入仲裁逻辑: Host 优先 (或者由 Controller 保证不冲突)
    // 这里简单实现: 如果 Host 写使能，则 Host 写；否则 VPU 写。
    assign ub_final_wr_en   = host_wr_en || aligned_wr_valid;
    assign ub_final_wr_addr = host_wr_en ? host_wr_addr : ctrl_wr_addr_d;
    assign ub_final_wr_data = host_wr_en ? host_wr_data : aligned_wr_data;

    unified_buffer #(
        .DATA_WIDTH(DATA_WIDTH_ACCUM),
        .SYSTOLIC_ARRAY_WIDTH(W),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) ub_inst (
        .clk(clk),
        
        // 写端口
        .wr_addr(ub_final_wr_addr),
        .wr_en(ub_final_wr_en),
        .wr_data(ub_final_wr_data),

        // 读端口
        .rd_addr_a(ctrl_rd_addr_a), .rd_en_a(ctrl_rd_en_a), .rd_data_a(ub_rd_a),
        .rd_addr_b(ctrl_rd_addr_b), .rd_en_b(ctrl_rd_en_b), .rd_data_b(ub_rd_b),
        .rd_addr_c(ctrl_rd_addr_c), .rd_en_c(ctrl_rd_en_c), .rd_data_c(ub_rd_c)
    );

    // ========================================================================
    // 逻辑 2: 数据截断 & 输入准备
    // ========================================================================
    genvar i, k;
    generate
        for (i = 0; i < W; i++) begin : trunc_gen
            // UB 输出 32位，Systolic 输入 8位，取低8位
            assign sys_in_a_raw[i] = ub_rd_a[i][DATA_WIDTH_IN-1:0];
            assign sys_in_b_raw[i] = ub_rd_b[i][DATA_WIDTH_IN-1:0];
        end
    endgenerate

    // ========================================================================
    // 模块 3: Skew Logic (关键时序对齐)
    // ========================================================================
    // 我们需要构建两组移位寄存器链
    
    generate
        // --- A-Flow Skew (Top Inputs) ---
        // 第 j 列延迟 j 个周期
        for (i = 0; i < W; i++) begin : a_skew_gen
            if (i == 0) begin
                // 第 0 列不延迟
                assign sys_in_a_skewed[i] = sys_in_a_raw[i];
                assign sys_idx_skewed[i]  = ctrl_weight_index;
                assign sys_acc_skewed[i]  = ctrl_accept_w;
            end else begin
                // 定义 i 级深的移位寄存器
                logic signed [DATA_WIDTH_IN-1:0] delay_data [i];
                logic [$clog2(W)-1:0]            delay_idx  [i];
                logic                            delay_acc  [i];

                always_ff @(posedge clk) begin
                    if (rst) begin
                        for(int d=0; d<i; d++) begin
                            delay_data[d] <= '0; delay_idx[d] <= '0; delay_acc[d] <= '0;
                        end
                    end else begin
                        // 链头输入
                        delay_data[0] <= sys_in_a_raw[i];
                        delay_idx[0]  <= ctrl_weight_index;
                        delay_acc[0]  <= ctrl_accept_w;
                        // 链中间移位
                        for(int d=1; d<i; d++) begin
                            delay_data[d] <= delay_data[d-1];
                            delay_idx[d]  <= delay_idx[d-1];
                            delay_acc[d]  <= delay_acc[d-1];
                        end
                    end
                end
                // 链尾输出
                assign sys_in_a_skewed[i] = delay_data[i-1];
                assign sys_idx_skewed[i]  = delay_idx[i-1];
                assign sys_acc_skewed[i]  = delay_acc[i-1];
            end
        end

        // --- B-Flow Skew (Left Inputs) ---
        // 第 i 行延迟 i 个周期
        for (i = 0; i < W; i++) begin : b_skew_gen
            if (i == 0) begin
                assign sys_in_b_skewed[i] = sys_in_b_raw[i];
                assign sys_val_skewed[i]  = ctrl_sys_valid;
                assign sys_sw_skewed[i]   = ctrl_sys_switch;
            end else begin
                logic signed [DATA_WIDTH_IN-1:0] delay_data [i];
                logic                            delay_val  [i];
                logic                            delay_sw   [i];

                always_ff @(posedge clk) begin
                    if (rst) begin
                        for(int d=0; d<i; d++) begin
                            delay_data[d] <= '0; delay_val[d] <= '0; delay_sw[d] <= '0;
                        end
                    end else begin
                        delay_data[0] <= sys_in_b_raw[i];
                        delay_val[0]  <= ctrl_sys_valid;
                        delay_sw[0]   <= ctrl_sys_switch;
                        for(int d=1; d<i; d++) begin
                            delay_data[d] <= delay_data[d-1];
                            delay_val[d]  <= delay_val[d-1];
                            delay_sw[d]   <= delay_sw[d-1];
                        end
                    end
                end
                assign sys_in_b_skewed[i] = delay_data[i-1];
                assign sys_val_skewed[i]  = delay_val[i-1];
                assign sys_sw_skewed[i]   = delay_sw[i-1];
            end
        end
    endgenerate

    // ========================================================================
    // 模块 4: Systolic Array
    // ========================================================================
    systolic #(
        .SYSTOLIC_ARRAY_WIDTH(W),
        .DATA_WIDTH_IN(DATA_WIDTH_IN),
        .DATA_WIDTH_ACCUM(DATA_WIDTH_ACCUM)
    ) sys_inst (
        .clk(clk),
        .rst(rst),
        // A-Flow
        .sys_weight_in(sys_in_a_skewed),
        .sys_index_in(sys_idx_skewed),
        .sys_accept_w_in(sys_acc_skewed),
        // B-Flow
        .sys_data_in(sys_in_b_skewed),
        .sys_valid_in(sys_val_skewed),
        .sys_switch_in(sys_sw_skewed),
        // Controls
        .sys_enable_rows(ctrl_row_mask),
        .sys_enable_cols(ctrl_col_mask),
        // Output
        .sys_data_out(sys_out_data),
        .sys_valid_out(sys_out_valid)
    );

    // ========================================================================
    // 模块 5: VPU (Vector Processing Unit)
    // ========================================================================
    vpu #(
        .VPU_WIDTH(W),
        .DATA_WIDTH_IN(DATA_WIDTH_ACCUM)
    ) vpu_inst (
        .clk(clk),
        .rst(rst),
        .vpu_mode(ctrl_vpu_mode),
        // 来自 Systolic 的输入
        .vpu_sys_data_in(sys_out_data),
        .vpu_sys_valid_in(sys_out_valid),
        // 来自 UB 的 Bias (假设 Controller 已经处理好 Bias 的读取时序)
        .vpu_bias_data_in(ub_rd_c),
        // 输出
        .vpu_data_out(vpu_out_data),
        .vpu_valid_out(vpu_out_valid)
    );

    // ========================================================================
    // 模块 6: Output De-skew Logic (输出对齐)
    // ========================================================================
    // Systolic 输出是梯形的：Col 0 早，Col 15 晚。
    // VPU 保留了这个梯形特性。
    // 为了整行写入 UB，我们需要把早到的数据 Delay，直到最晚的数据到达。
    // 延迟量：Col j 需要延迟 (W - 1 - j) 拍。
    
    generate
        for (i = 0; i < W; i++) begin : deskew_gen
            localparam int DELAY = (W - 1) - i;

            if (DELAY == 0) begin
                // 最后一列 (Col 15) 不需要延迟，它就是基准
                assign aligned_wr_data[i] = vpu_out_data[i];
            end else begin
                logic signed [DATA_WIDTH_ACCUM-1:0] pipe_out [DELAY];
                
                always_ff @(posedge clk) begin
                    if (rst) begin
                        for(int d=0; d<DELAY; d++) pipe_out[d] <= '0;
                    end else begin
                        // 链头 (注意: 这里需要用 valid 门控吗？SRAM 写使能由 valid 决定，数据可以乱跳)
                        // 为了简单，直接移位数据
                        pipe_out[0] <= vpu_out_data[i];
                        for(int d=1; d<DELAY; d++) begin
                            pipe_out[d] <= pipe_out[d-1];
                        end
                    end
                end
                assign aligned_wr_data[i] = pipe_out[DELAY-1];
            end
        end
    endgenerate

    // 生成最终的写使能
    // 当且仅当最晚的一列 (Col W-1) 有效，并且经过了对齐延迟后，整行才算有效。
    // 实际上，只要检查最后一列的 valid 信号是否到达即可（因为它没有延迟）
    // 或者是检查第一列经过了最大延迟后的 valid。它们在时间上是对齐的。
    assign aligned_wr_valid = vpu_out_valid[W-1]; 
    assign writeback_done   = aligned_wr_valid;

endmodule
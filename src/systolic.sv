`timescale 1ns/1ps
`default_nettype none

/**
 * 脉动阵列 (Systolic Array) 模块
 * 规范: 16x16 阵列, int8 输入 (A, B), int32 累加 (E)
 * 实现了 E = A*B (矩阵乘法部分)
 * * 采用了“双缓冲、1周期延迟、流水线寻址”设计
 * * B-Flow (权重加载):
 * - North-to-South (垂直)
 * - 信号: pe_weight, pe_index, pe_accept_w
 * - 协议: PE[i][j] 在 pe_index_in == ROW_ID (i) 时 "吞噬" 信号并锁存
 * * A-Flow (计算):
 * - West-to-East (水平)
 * - 信号: pe_input, pe_valid, pe_switch
 * - 协议: pe_switch_in 必须在 pe_valid_in 之前一个周期 (插入 "气泡")
 * * Psum-Flow (结果):
 * - North-to-South (垂直)
 * - 信号: pe_psum
*
 * (已修改: 1. 支持精确的行列使能控制)
 * (已修改: 2. 修复了 sys_valid_out 逻辑，使其与 Psum 流对齐)
 */
module systolic #(
    parameter int SYSTOLIC_ARRAY_WIDTH = 16,
    parameter int DATA_WIDTH_IN       = 8,
    parameter int DATA_WIDTH_ACCUM    = 32
)(
    input logic clk,
    input logic rst,

    // --- 输入 (来自左侧, 矩阵 A) ---
    // 每个 'i' 对应阵列的第 'i' 行
    input logic signed [DATA_WIDTH_IN-1:0]   sys_data_in [SYSTOLIC_ARRAY_WIDTH],
    input logic                             sys_valid_in [SYSTOLIC_ARRAY_WIDTH],
    input logic                             sys_switch_in [SYSTOLIC_ARRAY_WIDTH],

    // --- 输入 (来自顶部, 矩阵 B 和 索引) ---
    // 每个 'j' 对应阵列的第 'j' 列
    input logic signed [DATA_WIDTH_IN-1:0]             sys_weight_in [SYSTOLIC_ARRAY_WIDTH],
    input logic [$clog2(SYSTOLIC_ARRAY_WIDTH)-1:0] sys_index_in [SYSTOLIC_ARRAY_WIDTH],
    input logic                                     sys_accept_w_in [SYSTOLIC_ARRAY_WIDTH],

    // --- 输出 (去往底部, 矩阵 E) ---
    // 每个 'j' 对应阵列的第 'j' 列的最终Psum
    output logic signed [DATA_WIDTH_ACCUM-1:0] sys_data_out [SYSTOLIC_ARRAY_WIDTH],
    output logic                               sys_valid_out [SYSTOLIC_ARRAY_WIDTH],

// --- 控制 (已修改) ---
    // 移除了 ub_rd_col_size_in 和 ub_rd_col_size_valid_in 
    
    //A [m * k]   B[k * n]   E\C\D[m * n] 
    //! sys_enable_rows: 'K' 维度的掩码 (启用 PE 行 i)
    //! sys_enable_cols: 'N' 维度的掩码 (启用 PE 列 j)
    input logic [SYSTOLIC_ARRAY_WIDTH-1:0] sys_enable_rows,  
    input logic [SYSTOLIC_ARRAY_WIDTH-1:0] sys_enable_cols
);

    localparam W = SYSTOLIC_ARRAY_WIDTH; // 别名, 简化代码

    // --- PE 使能逻辑 (已删除) ---
    // 原始的 always_ff 块 [cite: 6-10] 已被移除

    // --- 内部连接线网 ---
    // 我们需要 (W+1) 的维度来轻松处理边界 (输入和输出)

    // 水平传播的线网 (W行, W+1列)
    logic signed [DATA_WIDTH_IN-1:0]   data_in_grid   [W][W+1]; // A-Flow
    logic                              valid_in_grid  [W][W+1]; // A-Flow
    logic                              switch_in_grid [W][W+1]; // A-Flow

    // 垂直传播的线网 (W+1行, W列)
    logic signed [DATA_WIDTH_IN-1:0]             weight_in_grid [W+1][W]; // B-Flow
    logic [$clog2(W)-1:0]                        index_in_grid  [W+1][W]; // B-Flow
    logic                                        accept_w_grid  [W+1][W]; // B-Flow
    logic signed [DATA_WIDTH_ACCUM-1:0]          psum_in_grid   [W+1][W]; // Psum-Flow
    logic                                        psum_valid_grid [W+1][W]; // <-- 新增: Psum Valid 线网


    // --- 声明和连接PE的 Generate 块 ---
    genvar i, j;
    generate
        // --- 1. 连接阵列的 顶部(Top) 和 左侧(Left) 边界 ---
        for (i = 0; i < W; i++) begin : row_inputs_gen
            // 连接最左侧(j=0)的PE输入 到 模块的输入端口
            assign data_in_grid[i][0]   = sys_data_in[i];
            assign valid_in_grid[i][0]  = sys_valid_in[i];
            assign switch_in_grid[i][0] = sys_switch_in[i];
        end

        for (j = 0; j < W; j++) begin : col_inputs_gen
            // 连接最顶部(i=0)的PE输入 到 模块的输入端口
            assign weight_in_grid[0][j] = sys_weight_in[j];
            assign index_in_grid[0][j]  = sys_index_in[j];
            assign accept_w_grid[0][j]  = sys_accept_w_in[j];
            // Psum (累加和) 总是从 0 开始
            assign psum_in_grid[0][j]   = 32'b0;
            assign psum_valid_grid[0][j] = 1'b0; // <-- 新增: Psum valid 也从 0 (false) 开始
        end

        // --- 2. 实例化 16x16 PE 网格 ---
        // i = 行, j = 列
        for (i = 0; i < W; i++) begin : row_pe_gen
            for (j = 0; j < W; j++) begin : col_pe_gen

                // --- 新的精确使能逻辑 ---
                // PE[i][j] 仅当其'行(i)'和'列(j)'都处于掩码中时才被使能
                wire pe_ij_enabled = sys_enable_rows[i] && sys_enable_cols[j];
                
                pe #(
                    .ROW_ID(i),  // <-- 核心修改: 传递PE的行ID
                    .SYSTOLIC_ARRAY_WIDTH(W),
                    .DATA_WIDTH_IN(DATA_WIDTH_IN),
                    .DATA_WIDTH_ACCUM(DATA_WIDTH_ACCUM)
                ) pe_inst (
                    .clk(clk),
                    .rst(rst),
                    
                    // --- 控制信号 ---
                    .pe_enabled(pe_ij_enabled),         // <-- 新的精确连接 [cite: 25]
                    .pe_accept_w_in(accept_w_grid[i][j]), // [i][j]   <- 来自上方
                    .pe_valid_in(valid_in_grid[i][j]),   // [i][j]   <- 来自左侧
                    .pe_switch_in(switch_in_grid[i][j]), // [i][j]   <- 来自左侧

                    // --- 数据输入 (North & West) ---
                    .pe_weight_in(weight_in_grid[i][j]), // [i][j]   <- 来自上方
                    .pe_index_in(index_in_grid[i][j]),   // [i][j]   <- 来自上方
                    .pe_psum_in(psum_in_grid[i][j]),     // [i][j]   <- 来自上方
                    .pe_psum_valid_in(psum_valid_grid[i][j]), // <-- 新增连接
                    .pe_input_in(data_in_grid[i][j]),    // [i][j]   <- 来自左侧

                    // --- 数据输出 (South & East) ---
                    // 垂直
                    .pe_weight_out(weight_in_grid[i+1][j]), // [i+1][j] -> 去往下方
                    .pe_index_out(index_in_grid[i+1][j]),   // [i+1][j] -> 去往下方
                    .pe_accept_w_out(accept_w_grid[i+1][j]), // [i+1][j] -> 去往下方
                    .pe_psum_out(psum_in_grid[i+1][j]),  // [i+1][j] -> 去往下方
                    .pe_psum_valid_out(psum_valid_grid[i+1][j]), // <-- 新增连接
                    
                    // 水平
                    .pe_input_out(data_in_grid[i][j+1]),   // [i][j+1] -> 去往右方
                    .pe_valid_out(valid_in_grid[i][j+1]),  // [i][j+1] -> 去往右方
                    .pe_switch_out(switch_in_grid[i][j+1])  // [i][j+1] -> 去往右方
                );
            end
        end

        // --- 3. 连接阵列的 底部(Bottom) 和 右侧(Right) 边界 ---
        for (j = 0; j < W; j++) begin : bottom_outputs_gen
            // 连接最底部(i=W)的Psum输出 到 模块的输出端口
            assign sys_data_out[j] = psum_in_grid[W][j];
            
            // 修复: sys_valid_out 现在来自新的 psum_valid_grid [cite: 32]
            assign sys_valid_out[j] = psum_valid_grid[W][j]; // <-- 关键修复
        end
        
        // (右侧和底部的其他输出信号在此设计中被丢弃，
        //  Verilog综合器会自动处理掉这些未连接的线网)

    endgenerate

endmodule
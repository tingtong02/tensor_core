`timescale 1ns/1ps
`default_nettype none

// Verilog (非 SystemVerilog) 版本的 systolic 模块
// 修改: 
// 1. 维度从 2x2 硬编码改为 WIDTH x WIDTH (默认 16x16)
// 2. 数据类型改为 int8 (data/weight) 和 int32 (psum)
// 3. 修正了 sys_start 逻辑 (每行一个)
// 4. 使用 generate for 循环例化 PE
module systolic #(
    parameter WIDTH = 16 // 默认 16x16
)(
    input wire clk,
    input wire rst,

    // --- 输入 (来自左侧, 矩阵 A) ---
    // 修改: [15:0] -> signed [7:0], 端口数组化
    input wire signed [7:0] sys_data_in [WIDTH-1:0], 
    // 修改: 修正了 valid 逻辑, 每行一个启动信号
    input wire sys_start_in [WIDTH-1:0],

    // --- 输出 (来自底部, 矩阵 A*B) ---
    // 修改: [15:0] -> signed [31:0], 端口数组化
    output wire signed [31:0] sys_data_out [WIDTH-1:0],
    // 修改: 端口数组化
    output wire sys_valid_out [WIDTH-1:0],

    // --- 输入 (来自顶部, 矩阵 B) ---
    // 修改: [15:0] -> signed [7:0], 端口数组化
    input wire signed [7:0] sys_weight_in [WIDTH-1:0],
    // 修改: 端口数组化 (此信号广播到整列)
    input wire sys_accept_w_in [WIDTH-1:0],

    // --- 控制信号 ---
    // switch 信号从左上角 [0,0] 注入
    input wire sys_switch_in,
    // 用于 PE 列使能的列大小
    input wire [15:0] ub_rd_col_size_in,
    input wire ub_rd_col_size_valid_in
);

    // --- PE 列使能逻辑 ---
    // 修改: 宽度参数化 (原 [1:0])
    reg [WIDTH-1:0] pe_enabled;
    
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pe_enabled <= 0;
        end else begin
            if (ub_rd_col_size_valid_in) begin
                // (1 << N) - 1 会生成 N 个 1
                // (例如: 1 << 3 = 1000b, -1 = 0111b)
                // 此逻辑  可以完美扩展
                pe_enabled <= (1 << ub_rd_col_size_in) - 1;
            end
        end
    end

    // --- 内部 2D 连线 ---
    // Verilog-2001 的 2D 数组 wire 声明 (iverilog 支持)
    
    // 水平传播 (Left-to-Right)
    wire signed [7:0]  pe_input_out_internal [WIDTH-1:0][WIDTH-1:0];
    wire               pe_valid_out_internal [WIDTH-1:0][WIDTH-1:0];
    
    // 垂直传播 (Top-to-Bottom)
    wire signed [31:0] pe_psum_out_internal  [WIDTH-1:0][WIDTH-1:0];
    wire signed [7:0]  pe_weight_out_internal[WIDTH-1:0][WIDTH-1:0];
    
    // 混合传播 (如原始代码实现)
    wire               pe_switch_out_internal[WIDTH-1:0][WIDTH-1:0];


    // --- 2D Generate 循环例化 PE 阵列 ---
    genvar i, j; // Verilog-2001 需要 genvar
    
    generate
    for (i = 0; i < WIDTH; i = i + 1) begin : row_gen
        for (j = 0; j < WIDTH; j = j + 1) begin : col_gen
            
            // 例化 PE (i = row, j = col)
            pe pe_inst (
                .clk(clk),
                .rst(rst),
                // pe_enabled[j] 控制第 j *列* 是否使能
                .pe_enabled(pe_enabled[j]),

                // --- North (Top) Connections ---
                // Psum 输入: 第 0 行 (i=0) 接 0, 否则接上一行 (i-1) 的输出
                .pe_psum_in((i == 0) ? 32'b0 : pe_psum_out_internal[i-1][j]),
                // Weight 输入: 第 0 行 (i=0) 接模块输入, 否则接上一行 (i-1) 的输出
                .pe_weight_in((i == 0) ? sys_weight_in[j] : pe_weight_out_internal[i-1][j]),
                // Accept W 输入: 直接连接到模块的列输入 (广播到整列)
                .pe_accept_w_in(sys_accept_w_in[j]),

                // --- West (Left) Connections ---
                // **修正:** Data/Valid 严格从左到右传播
                // Input 输入: 第 0 列 (j=0) 接模块输入, 否则接左一列 (j-1) 的输出
                .pe_input_in((j == 0) ? sys_data_in[i] : pe_input_out_internal[i][j-1]),
                // Valid 输入: 第 0 列 (j=0) 接模块输入, 否则接左一列 (j-1) 的输出
                .pe_valid_in((j == 0) ? sys_start_in[i] : pe_valid_out_internal[i][j-1]),
                
                // --- Switch Connection (保留原始代码的混合传播) ---
                .pe_switch_in(
                    (i == 0) ? 
                        // 如果是第 0 行:
                        //  (j=0) ? 从模块输入 : 从左侧 (j-1)
                        ((j == 0) ? sys_switch_in : pe_switch_out_internal[0][j-1]) :
                        // 如果不是第 0 行:
                        //  从顶部 (i-1)
                        pe_switch_out_internal[i-1][j]
                ),

                // --- South (Bottom) Connections ---
                .pe_psum_out(pe_psum_out_internal[i][j]),
                .pe_weight_out(pe_weight_out_internal[i][j]),

                // --- East (Right) Connections ---
                .pe_input_out(pe_input_out_internal[i][j]),
                .pe_valid_out(pe_valid_out_internal[i][j]),
                .pe_switch_out(pe_switch_out_internal[i][j])
            );

        end
    end
    endgenerate

    // --- 最终输出分配 ---
    // 将阵列最底行 (i=WIDTH-1) 的 Psum/Valid 输出连接到模块输出
    generate
    for (j = 0; j < WIDTH; j = j + 1) begin : output_assign_gen
        assign sys_data_out[j]  = pe_psum_out_internal[WIDTH-1][j];
        assign sys_valid_out[j] = pe_valid_out_internal[WIDTH-1][j];
    end
    endgenerate

endmodule
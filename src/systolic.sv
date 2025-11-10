`timescale 1ns/1ps
`default_nettype none

// 参数化 $N x N$ 阵列, 默认 16x16
module systolic #(
    parameter int SYSTOLIC_ARRAY_WIDTH = 16
)(
    input logic clk,
    input logic rst,

    // --- West Inputs (Data A) ---
    // 端口数组化, int8
    input logic signed [ 7:0] sys_data_in   [SYSTOLIC_ARRAY_WIDTH-1:0],
    input logic               sys_valid_in  [SYSTOLIC_ARRAY_WIDTH-1:0],

    // --- North Inputs (Data B) ---
    // 端口数组化, int8
    input logic signed [ 7:0] sys_weight_in [SYSTOLIC_ARRAY_WIDTH-1:0],
    input logic               sys_accept_w  [SYSTOLIC_ARRAY_WIDTH-1:0],

    // --- South Outputs (Data D) ---
    // 端口数组化, int32
    output logic signed [31:0] sys_data_out  [SYSTOLIC_ARRAY_WIDTH-1:0],
    output logic               sys_valid_out [SYSTOLIC_ARRAY_WIDTH-1:0], // 来自最后一行的 pe_valid_out

    // --- Control Signals ---
    input logic               sys_switch_in [SYSTOLIC_ARRAY_WIDTH-1:0], 
    input logic [15:0]        ub_rd_col_size_in,
    input logic               ub_rd_col_size_valid_in
);

    // --- 内部连线网格 ---
    logic signed [ 7:0] pe_input_out  [SYSTOLIC_ARRAY_WIDTH-1:0][SYSTOLIC_ARRAY_WIDTH-1:0];
    logic signed [ 7:0] pe_weight_out [SYSTOLIC_ARRAY_WIDTH-1:0][SYSTOLIC_ARRAY_WIDTH-1:0];
    logic signed [31:0] pe_psum_out   [SYSTOLIC_ARRAY_WIDTH-1:0][SYSTOLIC_ARRAY_WIDTH-1:0];
    logic               pe_valid_out  [SYSTOLIC_ARRAY_WIDTH-1:0][SYSTOLIC_ARRAY_WIDTH-1:0];
    logic               pe_switch_out [SYSTOLIC_ARRAY_WIDTH-1:0][SYSTOLIC_ARRAY_WIDTH-1:0];

    // --- PE 使能控制 ---
    logic [SYSTOLIC_ARRAY_WIDTH-1:0] pe_enabled;


    // --- 动态生成 PE 阵列 (修正版) ---
    // 使用 4-way 'generate if' 消除所有 iverilog 边界警告 
    genvar i, j;
    generate
        for (i = 0; i < SYSTOLIC_ARRAY_WIDTH; i++) begin : row_gen
            for (j = 0; j < SYSTOLIC_ARRAY_WIDTH; j++) begin : col_gen
                
                // Case 1: 顶-左角 PE (i=0, j=0)
                if (i == 0 && j == 0) begin
                    pe pe_inst_corner_0_0 (
                        .clk(clk), .rst(rst), .pe_enabled(pe_enabled[j]),
                        // North (from module input)
                        .pe_psum_in(32'b0),
                        .pe_weight_in(sys_weight_in[j]),
                        .pe_accept_w_in(sys_accept_w[j]),
                        // West (from module input)
                        .pe_input_in(sys_data_in[i]),
                        .pe_valid_in(sys_valid_in[i]),
                        .pe_switch_in(sys_switch_in[i]),
                        // South/East (to internal wires)
                        .pe_psum_out(pe_psum_out[i][j]),
                        .pe_weight_out(pe_weight_out[i][j]),
                        .pe_input_out(pe_input_out[i][j]),
                        .pe_valid_out(pe_valid_out[i][j]),
                        .pe_switch_out(pe_switch_out[i][j])
                    );
                end
                // Case 2: 顶行, 非角 PE (i=0, j>0)
                else if (i == 0 && j > 0) begin
                    pe pe_inst_row_0 (
                        .clk(clk), .rst(rst), .pe_enabled(pe_enabled[j]),
                        // North (from module input)
                        .pe_psum_in(32'b0),
                        .pe_weight_in(sys_weight_in[j]),
                        .pe_accept_w_in(sys_accept_w[j]),
                        // West (from left PE)
                        .pe_input_in(pe_input_out[i][j-1]),
                        .pe_valid_in(pe_valid_out[i][j-1]),
                        .pe_switch_in(pe_switch_out[i][j-1]),
                        // South/East (to internal wires)
                        .pe_psum_out(pe_psum_out[i][j]),
                        .pe_weight_out(pe_weight_out[i][j]),
                        .pe_input_out(pe_input_out[i][j]),
                        .pe_valid_out(pe_valid_out[i][j]),
                        .pe_switch_out(pe_switch_out[i][j])
                    );
                end
                // Case 3: 左列, 非角 PE (i>0, j=0)
                else if (i > 0 && j == 0) begin
                    pe pe_inst_col_0 (
                        .clk(clk), .rst(rst), .pe_enabled(pe_enabled[j]),
                        // North (from upper PE)
                        .pe_psum_in(pe_psum_out[i-1][j]),
                        .pe_weight_in(pe_weight_out[i-1][j]),
                        .pe_accept_w_in(sys_accept_w[j]),
                        // West (from module input)
                        .pe_input_in(sys_data_in[i]),
                        .pe_valid_in(sys_valid_in[i]),
                        .pe_switch_in(sys_switch_in[i]),
                        // South/East (to internal wires)
                        .pe_psum_out(pe_psum_out[i][j]),
                        .pe_weight_out(pe_weight_out[i][j]),
                        .pe_input_out(pe_input_out[i][j]),
                        .pe_valid_out(pe_valid_out[i][j]),
                        .pe_switch_out(pe_switch_out[i][j])
                    );
                end
                // Case 4: 内部 PEs (i>0, j>0)
                else begin // (i > 0 && j > 0)
                    pe pe_inst_internal (
                        .clk(clk), .rst(rst), .pe_enabled(pe_enabled[j]),
                        // North (from upper PE)
                        .pe_psum_in(pe_psum_out[i-1][j]),
                        .pe_weight_in(pe_weight_out[i-1][j]),
                        .pe_accept_w_in(sys_accept_w[j]),
                        // West (from left PE)
                        .pe_input_in(pe_input_out[i][j-1]),
                        .pe_valid_in(pe_valid_out[i][j-1]),
                        .pe_switch_in(pe_switch_out[i][j-1]),
                        // South/East (to internal wires)
                        .pe_psum_out(pe_psum_out[i][j]),
                        .pe_weight_out(pe_weight_out[i][j]),
                        .pe_input_out(pe_input_out[i][j]),
                        .pe_valid_out(pe_valid_out[i][j]),
                        .pe_switch_out(pe_switch_out[i][j])
                    );
                end
                
            end
        end
    endgenerate

    // --- 模块输出连接 ---
    // 最终的 psum 结果来自阵列的最后一行
    // 最终的 valid 信号也来自阵列的最后一行
    generate
        for (j = 0; j < SYSTOLIC_ARRAY_WIDTH; j++) begin : output_gen
            assign sys_data_out[j]  = pe_psum_out[SYSTOLIC_ARRAY_WIDTH-1][j];
            assign sys_valid_out[j] = pe_valid_out[SYSTOLIC_ARRAY_WIDTH-1][j];
        end
    endgenerate


    // --- PE 使能逻辑 ---
    always_ff @(posedge clk or posedge rst) begin
        if(rst) begin
            pe_enabled <= '0;
        end else begin
            if(ub_rd_col_size_valid_in) begin
                // (1 << N) - 1 会生成 N 个 '1'
                pe_enabled <= (1 << ub_rd_col_size_in) - 1;
            end
        end
    end

endmodule
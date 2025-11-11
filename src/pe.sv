`timescale 1ns/1ps
`default_nettype none

/**
 * 处理单元 (PE) 模块
 * 规范: int8 输入, int32 累加
 * 特性: 索引匹配 (ROW_ID == pe_index_in)
 * "信号吞噬" (Signal-Eating) 逻辑：
 * 当索引匹配时，PE锁存权重，并停止 pe_accept_w 向下传播。
 */
module pe #(
    parameter int ROW_ID               = 0,  // 本PE的行索引 (静态, 由systolic.sv设置)
    parameter int SYSTOLIC_ARRAY_WIDTH = 16, // 阵列的总大小
    parameter int DATA_WIDTH_IN        = 8,  // A和B的位宽 (int8)
    parameter int DATA_WIDTH_ACCUM     = 32  // Psum的位宽 (int32)
) (
    input logic clk,
    input logic rst,

    // --- 控制信号 (West) ---
    input logic pe_valid_in,    // 1: 接收输入B, 进行MAC计算
    input logic pe_switch_in,   // 1: 切换 active/inactive 权重
    
    // --- 控制信号 (North) ---
    input logic pe_enabled,       // PE 使能 (来自systolic的列使能)
    input logic pe_accept_w_in, // 1: 权重(A)流有效
    
    // --- 数据端口 (North) ---
    input logic signed [DATA_WIDTH_IN-1:0]     pe_weight_in, // 8-bit 权重 (A)
    input logic [$clog2(SYSTOLIC_ARRAY_WIDTH)-1:0] pe_index_in,  // 权重(A)的索引 (即列号)
    input logic signed [DATA_WIDTH_ACCUM-1:0]   pe_psum_in,   // 32-bit Psum

    // --- 数据端口 (West) ---
    input logic signed [DATA_WIDTH_IN-1:0]     pe_input_in,  // 8-bit 输入 (B)

    // --- 数据端口 (South) ---
    output logic signed [DATA_WIDTH_IN-1:0]     pe_weight_out, // 8-bit 权重 (去往下方)
    output logic [$clog2(SYSTOLIC_ARRAY_WIDTH)-1:0] pe_index_out,  // 索引 (去往下方)
    output logic signed [DATA_WIDTH_ACCUM-1:0]   pe_psum_out,   // 32-bit Psum (去往下方)
    output logic                               pe_accept_w_out, // "流有效" (去往下方)

    // --- 数据端口 (East) ---
    output logic signed [DATA_WIDTH_IN-1:0]     pe_input_out,  // 8-bit 输入 (去往右方)
    output logic                               pe_valid_out,  // pe_valid_in 的1拍延迟
    output logic                               pe_switch_out  // pe_switch_in 的1拍延迟
);

    // --- 内部状态寄存器 ---
    logic signed [DATA_WIDTH_IN-1:0] weight_reg_active;   // 8-bit: 用于计算的激活权重
    logic signed [DATA_WIDTH_IN-1:0] weight_reg_inactive; // 8-bit: 用于加载的后台权重

    // --- 组合逻辑: MAC 单元 ---
    logic signed [(DATA_WIDTH_IN*2)-1:0] mult_result;
    logic signed [DATA_WIDTH_ACCUM-1:0] mac_out;
    wire                                pe_match;

    // 乘法器: B * A
    assign mult_result = pe_input_in * weight_reg_active;

    // 加法器: (B * A) + Psum
    assign mac_out = $signed(mult_result) + pe_psum_in;

    // 匹配逻辑: 检查A的索引是否等于本PE的行ID
    assign pe_match = (pe_index_in == ROW_ID);


    // --- 时序逻辑: 寄存器更新 ---
    always_ff @(posedge clk or posedge rst) begin
        if (rst || !pe_enabled) begin
            // 复位所有输出
            pe_input_out        <= '0;
            pe_valid_out        <= 1'b0;
            pe_switch_out       <= 1'b0;
            pe_psum_out         <= '0;
            pe_weight_out       <= '0;
            pe_index_out        <= '0;
            pe_accept_w_out     <= 1'b0;

            // 复位所有内部状态
            weight_reg_active   <= '0;
            weight_reg_inactive <= '0;
        
        end else begin
            
            // --- 1. 信号传播 (West-to-East) ---
            // B, valid, switch 信号水平传递
            pe_input_out  <= pe_input_in;
            pe_valid_out  <= pe_valid_in;
            pe_switch_out <= pe_switch_in;

            // --- 2. 信号传播 (North-to-South) ---
            
            // 2a. A的数据和索引 *总是* 向下传递
            pe_weight_out <= pe_weight_in;
            pe_index_out  <= pe_index_in;
            
            // 2b. Psum 仅在B流有效时才计算并传递
            if (pe_valid_in) begin
                pe_psum_out <= mac_out;
            end else begin
                pe_psum_out <= '0; // 刷新管道
            end

            // 2c. “信号吞噬”逻辑 (A的加载)
            if (pe_accept_w_in) begin
                if (pe_match) begin
                    // 索引匹配: 锁存权重, 并"吞噬"accept信号 (不再下传)
                    weight_reg_inactive <= pe_weight_in;
                    pe_accept_w_out     <= 1'b0;
                end else begin
                    // 索引不匹配: 传递accept信号
                    pe_accept_w_out     <= 1'b1;
                end
            end else begin
                // A流无效: 不传递accept信号
                pe_accept_w_out <= 1'b0;
            end
            
            // --- 3. 内部权重切换 ---
            // 当B流的第一个元素到达时，切换权重
            if (pe_switch_in) begin
                weight_reg_active <= weight_reg_inactive;
            end
        end
    end

endmodule
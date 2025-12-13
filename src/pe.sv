`timescale 1ns/1ps
`default_nettype none

/**
 * 处理单元 (PE) 模块
 * 规范: int8 输入, int32 累加
 * 特性: 索引匹配 (ROW_ID == pe_index_in)
 * "信号吞噬" (Signal-Eating) 逻辑：
 * 当索引匹配时，PE锁存权重，并停止 pe_accept_w 向下传播。
 * (已修改: 添加了专用的 Psum Valid 流水线)
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
    input logic pe_valid_in,    // 1: 接收输入A, 进行MAC计算
    input logic pe_switch_in,   // 1: 切换 active/inactive 权重
    
    // --- 控制信号 (North) ---
    input logic pe_enabled,       // PE 使能 (来自systolic的列使能)
    input logic pe_accept_w_in, // 1: 权重(B)流有效
    
    // --- 数据端口 (North) ---
    input logic signed [DATA_WIDTH_IN-1:0]     pe_weight_in, // 8-bit 权重 (B)
    input logic [$clog2(SYSTOLIC_ARRAY_WIDTH)-1:0] pe_index_in,  // 权重(B)的索引 (即行号)
    input logic signed [DATA_WIDTH_ACCUM-1:0]   pe_psum_in,   // 32-bit Psum
    input logic                                 pe_psum_valid_in, // <-- 新增: Psum的有效信号

    // --- 数据端口 (West) ---
    input logic signed [DATA_WIDTH_IN-1:0]     pe_input_in,  // 8-bit 输入 (A)

    // --- 数据端口 (South) ---
    output logic signed [DATA_WIDTH_IN-1:0]     pe_weight_out, // 8-bit 权重 (去往下方)
    output logic [$clog2(SYSTOLIC_ARRAY_WIDTH)-1:0] pe_index_out,  // 索引 (去往下方)
    output logic signed [DATA_WIDTH_ACCUM-1:0]   pe_psum_out,   // 32-bit Psum (去往下方)
    output logic                                pe_psum_valid_out, // <-- 新增: Psum的有效信号
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

    // 乘法器: A * B
    assign mult_result = pe_input_in * weight_reg_active;

    // 加法器: (A * B) + Psum
    assign mac_out = $signed(mult_result) + pe_psum_in;

    // 匹配逻辑: 检查B的索引是否等于本PE的行ID
    // 使用 $clog2 确保代码的通用性
    localparam INDEX_WIDTH = $clog2(SYSTOLIC_ARRAY_WIDTH);

    // 显式地将 ROW_ID 转换为 4 位，然后再比较
    assign pe_match = (pe_index_in == INDEX_WIDTH'(ROW_ID)) && pe_accept_w_in; // 保护


// --- 时序逻辑: 寄存器更新 (已修正) ---
    always_ff @(posedge clk) begin
        if (rst) begin
            // --- 1. 同步复位: 永远最高优先级 ---
            // 复位所有输出
            pe_input_out        <= '0;
            pe_valid_out        <= 1'b0;
            pe_switch_out       <= 1'b0;
            pe_psum_out         <= '0;
            pe_psum_valid_out   <= 1'b0; // <-- 新增: 复位 Psum valid
            pe_weight_out       <= '0;
            pe_index_out        <= '0;
            pe_accept_w_out     <= 1'b0;

            // 复位所有内部状态
            weight_reg_active   <= '0;
            weight_reg_inactive <= '0;
            
        end else begin
            // --- 2. 非复位状态: 现在检查 'pe_enabled' ---
            if (pe_enabled) begin
                // --- PE 已使能: 正常运行 ---
                
                // (1. 信号传播 West-to-East)
                pe_input_out  <= pe_input_in;
                pe_valid_out  <= pe_valid_in;
                pe_switch_out <= pe_switch_in;

                // (2. 信号传播 North-to-South)
                
                // (2b. Psum 逻辑: 已修正)
                if (pe_valid_in) begin
                    pe_psum_out <= mac_out;
                end else begin
                    pe_psum_out <= pe_psum_in; // 直通
                end

                // [FIX] Psum Valid 必须是从上方传递下来的信号 (打一拍)
                // 这样 Valid 标志会跟随 Psum 数据一起向下流动
                pe_psum_valid_out <= pe_psum_valid_in;
                
                if (pe_accept_w_in && !pe_match) begin
                    // 状态 1: 传播 (Propagate)
                    // (pe_accept_w_in 为 1, 但索引不匹配)
                    pe_accept_w_out     <= 1'b1;
                    pe_weight_out       <= pe_weight_in;
                    pe_index_out        <= pe_index_in;
                end 
                else if (pe_accept_w_in && pe_match) begin
                    // 状态 2: 吞噬 (Eat)
                    // (pe_accept_w_in 为 1, 且索引匹配)
                    weight_reg_inactive <= pe_weight_in;
                    pe_accept_w_out     <= 1'b0;
                    pe_weight_out       <= '0;
                    pe_index_out        <= '0;
                end 
                else begin
                    // 状态 3: 停止 (Stop)
                    // (pe_accept_w_in 为 0)
                    pe_accept_w_out     <= 1'b0;
                    pe_weight_out       <= '0;
                    pe_index_out        <= '0;
                end
                // --- 修复结束 ---
                
                // (3. 内部权重切换)
                if (pe_switch_in) begin
                    weight_reg_active <= weight_reg_inactive;
                end

            end else begin
                // --- PE 已禁用: 充当直通管道 ---
                // (A/B 流被终止)
                pe_input_out        <= '0;
                pe_valid_out        <= 1'b0;
                pe_switch_out       <= 1'b0;
                pe_weight_out       <= '0;
                pe_index_out        <= '0;
                pe_accept_w_out     <= 1'b0;
                // (Psum 流被直通)
                pe_psum_out         <= pe_psum_in;         // <-- Psum 数据直通 
                pe_psum_valid_out   <= pe_psum_valid_in; // <-- 关键修复: Psum valid 也被直通
                // (内部状态可以保持复位)
                weight_reg_active   <= '0;
                weight_reg_inactive <= '0;
            end
        end
    end

endmodule
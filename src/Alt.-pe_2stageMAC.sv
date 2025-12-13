`timescale 1ns/1ps
//`default_nettype none

//!增加MACA两级流水线，先存乘法结果，再加上psum输入，但是需要修改B flow的输入，否侧会错位
//!还可以适当降低DATA_WIDTH_ACCUM     = 32，改为24位，节省资源，或者更低（20？ 18？）
//!比较麻烦的就是 one shot 代替 index，或者使用混合编码 3bits index + 8bit one shot 信号,或者4+4+4 one shot 信号

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
    input logic                                 pe_psum_valid_in, // <-- 新增: Psum的有效信号

    // --- 数据端口 (West) ---
    input logic signed [DATA_WIDTH_IN-1:0]     pe_input_in,  // 8-bit 输入 (B)

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
    
    // --- MAC 流水线寄存器 (新增) ---
    logic signed [DATA_WIDTH_IN*2-1:0]  mult_res_stage1;    // Stage 1: 乘法结果
    logic signed [DATA_WIDTH_ACCUM-1:0] psum_in_stage1;     // Stage 1: Psum 对齐
    logic                               valid_stage1;       // Stage 1: Valid 对齐

    // --- 组合逻辑: MAC 单元 ---
    logic signed [(DATA_WIDTH_IN*2)-1:0] mult_result;
    logic signed [DATA_WIDTH_ACCUM-1:0] mac_out;
    wire                                pe_match;

//    // 乘法器: B * A
//    assign mult_result = pe_input_in * weight_reg_active;

//    // 加法器: (B * A) + Psum
//    assign mac_out = $signed(mult_result) + pe_psum_in;

    // 匹配逻辑: 检查A的索引是否等于本PE的行ID
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
                
                // =================================================
                // 2. MAC 计算流水线 (Psum Flow)
                // =================================================
                
                // --- Stage 1: 乘法 & 输入对齐 ---
                // 将乘法和加法拆开，乘法结果存入中间寄存器
                mult_res_stage1 <= pe_input_in * weight_reg_active;
                
                // Psum 输入必须等待 1 拍，以便与乘法结果对齐
                psum_in_stage1  <= pe_psum_in;
                
                // Valid 信号同步打一拍
                valid_stage1    <= pe_valid_in;

                // --- Stage 2: 加法 & 输出 ---
                // 使用 Stage 1 寄存下来的值进行加法
                if (valid_stage1) begin
                    pe_psum_out <= $signed(mult_res_stage1) + psum_in_stage1;
                end else begin
                    pe_psum_out <= psum_in_stage1; // 如果无效，保持直通 (使用对齐后的psum)
                end
                
                // 输出 Valid
                pe_psum_valid_out <= valid_stage1;
                
                // (2c. "信号吞噬"逻辑)
                if (pe_accept_w_in) begin
                    if (pe_match) begin
                        weight_reg_inactive <= pe_weight_in;
                        pe_accept_w_out     <= 1'b0;
                        pe_weight_out       <= '0; // 停止传播 (或保持)
                        pe_index_out        <= '0; // 停止传播 (或保持)
                    end else begin
                        pe_accept_w_out     <= 1'b1;
                        pe_weight_out       <= pe_weight_in;  // <-- 移到这里
                        pe_index_out        <= pe_index_in;   // <-- 移到这里
                    end
                end else begin
                    pe_accept_w_out <= 1'b0;
                    pe_weight_out   <= '0; // (或保持上一拍的值)
                    pe_index_out    <= '0; // (或保持上一拍的值)
                end
                
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

                // 注意：禁用模式下，Psum 也需要经过流水线寄存器以保持一致的延迟，
                // 或者简单地直通 (取决于系统设计)。这里为了简单保持直通行为：
                pe_psum_out         <= pe_psum_in;
                pe_psum_valid_out   <= pe_psum_valid_in;

                // (内部状态可以保持复位)
                weight_reg_active   <= '0;
                weight_reg_inactive <= '0;
            end
        end
    end

endmodule

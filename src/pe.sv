`timescale 1ns/1ps
`default_nettype none

/**
 * 处理单元 (PE) 模块
 * 规范: int8 输入, int32 累加
 *
 * A (权重) 从 North -> South (pe_weight_in -> pe_weight_out)
 * B (输入) 从 West  -> East  (pe_input_in  -> pe_input_out)
 * C (Psum) 从 North -> South (pe_psum_in   -> pe_psum_out)
 */
module pe #(
    parameter int DATA_WIDTH_IN   = 8,   // A和B的位宽 (int8)
    parameter int DATA_WIDTH_ACCUM = 32   // Psum和C/D的位宽 (int32)
) (
    input logic clk,
    input logic rst,

    // --- 控制信号 ---
    input logic pe_enabled,       // PE 使能
    input logic pe_accept_w_in, // 1: 接收权重A, 存入inactive
    input logic pe_valid_in,    // 1: 接收输入B, 进行MAC计算
    input logic pe_switch_in,   // 1: 切换 active/inactive 权重

    // --- 数据端口 (North) ---
    input logic signed [DATA_WIDTH_ACCUM-1:0] pe_psum_in,   // 32-bit Psum (来自上方)
    input logic signed [DATA_WIDTH_IN-1:0]   pe_weight_in, // 8-bit 权重 (A)

    // --- 数据端口 (West) ---
    input logic signed [DATA_WIDTH_IN-1:0]   pe_input_in,  // 8-bit 输入 (B)

    // --- 数据端口 (South) ---
    output logic signed [DATA_WIDTH_ACCUM-1:0] pe_psum_out,  // 32-bit Psum (去往下方)
    output logic signed [DATA_WIDTH_IN-1:0]   pe_weight_out, // 8-bit 权重 (去往下方)

    // --- 数据端口 (East) ---
    output logic signed [DATA_WIDTH_IN-1:0]   pe_input_out,  // 8-bit 输入 (去往右方)
    output logic pe_valid_out,  // pe_valid_in 的1拍延迟
    output logic pe_switch_out  // pe_switch_in 的1拍延迟
);

    // --- 内部状态寄存器 ---
    logic signed [DATA_WIDTH_IN-1:0] weight_reg_active;   // 8-bit: 用于计算的当前权重
    logic signed [DATA_WIDTH_IN-1:0] weight_reg_inactive; // 8-bit: 用于加载的后台权重

    // --- 组合逻辑: MAC 单元 ---

    // 1. 乘法: 8-bit * 8-bit = 16-bit
    //    (需要 2 * DATA_WIDTH_IN 宽度来存储中间结果)
    logic signed [(DATA_WIDTH_IN*2)-1:0] mult_result;
    
    // 2. 加法: 16-bit + 32-bit = 32-bit
    //    (mac_out 是本PE的最终Psum)
    logic signed [DATA_WIDTH_ACCUM-1:0] mac_out;

    // 乘法器: B * A
    // (B 来自左侧, A 来自内部寄存器)
    assign mult_result = pe_input_in * weight_reg_active;

    // 加法器: (B * A) + Psum
    // (使用 $signed() 进行符号位扩展，将16-bit的乘法结果扩展为32-bit，
    //  然后再与32-bit的 pe_psum_in 相加)
    assign mac_out = $signed(mult_result) + pe_psum_in;


    // --- 时序逻辑: 寄存器更新 ---

    always_ff @(posedge clk or posedge rst) begin
        if (rst || !pe_enabled) begin
            // 复位所有输出
            pe_input_out        <= '0;
            pe_valid_out        <= 1'b0;
            pe_switch_out       <= 1'b0;
            pe_psum_out         <= '0;
            pe_weight_out       <= '0;

            // 复位所有内部状态
            weight_reg_active   <= '0;
            weight_reg_inactive <= '0;
        
        end else begin
            
            // --- 1. 信号传播 (West-to-East) ---
            // 寄存器化，延迟一拍传递到右侧
            pe_input_out  <= pe_input_in;
            pe_valid_out  <= pe_valid_in;
            pe_switch_out <= pe_switch_in;

            // --- 2. 信号传播 (North-to-South) ---
            
            // 2a. 传播权重 (A)
            // 当 pe_accept_w_in 有效时，将权重传递给下一个PE (South)
            if (pe_accept_w_in) begin
                pe_weight_out <= pe_weight_in;
            end else begin
                pe_weight_out <= '0; // 如果无效，不传播
            end

            // 2b. 传播部分和 (Psum)
            // 只有当 pe_valid_in (输入B) 有效时，才计算并输出新的Psum
            if (pe_valid_in) begin
                // mac_out 是 (pe_input_in * weight_reg_active) + pe_psum_in
                pe_psum_out <= mac_out;
            end else begin
                // 如果输入无效 (无B数据)，则将来自上方的Psum清零
                // 这用于在数据流的开头和末尾刷新管道
                pe_psum_out <= '0;
            end

            // --- 3. 内部权重寄存器更新 ---
            
            // 3a. 加载 权重A 到 "后台" 寄存器
            if (pe_accept_w_in) begin
                weight_reg_inactive <= pe_weight_in;
            end

            // 3b. 切换权重
            // 当 pe_switch_in (随矩阵B的第一个元素) 到达时，
            // 将 "后台" 权重激活到 "前台"
            if (pe_switch_in) begin
                weight_reg_active <= weight_reg_inactive;
            end
        end
    end

endmodule
`timescale 1ns/1ps
`default_nettype none

module pe (
    input logic clk,
    input logic rst,

    // North wires of PE
    input logic signed [31:0] pe_psum_in,        
    input logic signed [ 7:0] pe_weight_in,      
    input logic pe_accept_w_in, 
    
    // West wires of PE
    input logic signed [ 7:0] pe_input_in,       
    input logic pe_valid_in, 
    input logic pe_switch_in, 
    
    input logic pe_enabled,

    // South wires of the PE
    output logic signed [31:0] pe_psum_out,      
    output logic signed [ 7:0] pe_weight_out,    

    // East wires of the PE
    output logic signed [ 7:0] pe_input_out,     
    output logic pe_valid_out,
    output logic pe_switch_out
);

    // 内部线网和寄存器类型
    logic signed [15:0] mult_out;           // (int8 * int8) -> int16
    logic signed [31:0] mac_out;            // (int16 + int32) -> int32
    logic signed [ 7:0] weight_reg_active;  
    logic signed [ 7:0] weight_reg_inactive;

    // 乘法 (int8 * int8 = int16)
    assign mult_out = $signed(pe_input_in) * $signed(weight_reg_active); 

    // 加法 (int16 + int32 = int32)
    assign mac_out = $signed(mult_out) + $signed(pe_psum_in); 


    // --- 唯一的时序逻辑块 (已修正) ---
    always_ff @(posedge clk or posedge rst) begin
        if (rst || !pe_enabled) begin
            // 复位所有寄存器
            pe_input_out        <= 8'b0;
            weight_reg_active   <= 8'b0; 
            weight_reg_inactive <= 8'b0; 
            pe_valid_out        <= 1'b0; 
            pe_weight_out       <= 8'b0; 
            pe_switch_out       <= 1'b0; 
            pe_psum_out         <= 32'b0; 
        end else begin
            
            // --- 路径1: West-to-East 传播 (A 和 Valid 信号) ---
            // 这些信号像移位寄存器一样，每个周期都向东传递
            pe_valid_out  <= pe_valid_in;
            pe_input_out  <= pe_input_in;
            
            // --- 路径2: West-to-East 传播 (Switch 控制信号) ---
            pe_switch_out <= pe_switch_in;
            
            // --- 路径3: 权重加载与切换 (North-to-South 和 内部) ---
            if (pe_accept_w_in) begin
                weight_reg_inactive <= pe_weight_in;
                pe_weight_out       <= pe_weight_in;
            end else begin
                pe_weight_out <= 8'b0; 
            end

            if (pe_switch_in) begin
                weight_reg_active <= weight_reg_inactive; 
            end

            // --- 路径4: Psum 计算 (North-to-South) ---
            // !! 这是关键的修复 !!
            if (pe_valid_in) begin
                // 如果 West 来的数据有效，执行 MAC 运算
                pe_psum_out  <= mac_out; 
            end else begin
                // 如果 West 来的数据无效 (气泡)，
                // 则将 North 来的 psum 直接传递到 South
                // (实现一级流水线延迟)
                pe_psum_out  <= pe_psum_in; // <-- 修正: 之前是 32'b0
            end
        end
    end

endmodule
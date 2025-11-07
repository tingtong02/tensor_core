`timescale 1ns/1ps
`default_nettype none

module pe (
    input logic clk,
    input logic rst,

    // North wires of PE
    input logic signed [31:0] pe_psum_in,        // 修改: 16b -> 32b (int32)
    input logic signed [ 7:0] pe_weight_in,      // 修改: 16b -> 8b (int8)
    input logic pe_accept_w_in, 
    
    // West wires of PE
    input logic signed [ 7:0] pe_input_in,       // 修改: 16b -> 8b (int8)
    input logic pe_valid_in, 
    input logic pe_switch_in, 
    
    input logic pe_enabled,

    // South wires of the PE
    output logic signed [31:0] pe_psum_out,      // 修改: 16b -> 32b (int32)
    output logic signed [ 7:0] pe_weight_out,    // 修改: 16b -> 8b (int8)

    // East wires of the PE
    output logic signed [ 7:0] pe_input_out,     // 修改: 16b -> 8b (int8)
    output logic pe_valid_out,
    output logic pe_switch_out
);

    // 内部线网和寄存器类型修改
    logic signed [15:0] mult_out;           // (int8 * int8) -> int16
    logic signed [31:0] mac_out;            // (int16 + int32) -> int32
    logic signed [ 7:0] weight_reg_active;  // 修改: 16b -> 8b (int8)
    logic signed [ 7:0] weight_reg_inactive;// 修改: 16b -> 8b (int8)

    // 移除 fxp_mul，替换为原生乘法
    // int8 * int8 = int16
    assign mult_out = $signed(pe_input_in) * $signed(weight_reg_active);

    // 移除 fxp_add，替换为原生加法
    // int16 + int32 = int32
    // $signed() 确保符号扩展正确
    assign mac_out = $signed(mult_out) + $signed(pe_psum_in);

    // Only the switch flag is combinational (active register copies inactive register on the same clock cycle that switch flag is set)
    // That means inputs from the left side of the PE can load in on the same clock cycle that the switch flag is set
    always_comb begin
        if (pe_switch_in) begin
            weight_reg_active = weight_reg_inactive;
        end
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst || !pe_enabled) begin
            // 修改: 更新所有复位值为正确的位宽
            pe_input_out        <= 8'b0;
            weight_reg_active   <= 8'b0;
            weight_reg_inactive <= 8'b0;
            pe_valid_out        <= 1'b0;
            pe_weight_out       <= 8'b0;
            pe_switch_out       <= 1'b0;
            pe_psum_out         <= 32'b0; // 之前在 'else' 块中 [cite: 152]，但应在此处复位
        end else begin
            pe_valid_out  <= pe_valid_in;
            pe_switch_out <= pe_switch_in;
            
            // Weight register updates - only on clock edges
            if (pe_accept_w_in) begin
                weight_reg_inactive <= pe_weight_in;
                pe_weight_out       <= pe_weight_in;
            end else begin
                pe_weight_out <= 8'b0; // 修改: 16b -> 8b
            end

            if (pe_valid_in) begin
                pe_input_out <= pe_input_in;
                pe_psum_out  <= mac_out; // mac_out 现在是 32b
            end else begin
                pe_valid_out <= 1'b0;
                pe_psum_out  <= 32'b0; // 修改: 16b -> 32b
            end
        end
    end

endmodule
`timescale 1ns/1ps
`default_nettype none

/**
 * 模块名: output_buffer
 * 功能: 片上输出缓冲区 (SRAM)
 * 架构: 
 * - 深度: 2^ADDR_WIDTH (默认 1024)
 * - 宽度: SYSTOLIC_ARRAY_WIDTH * DATA_WIDTH (默认 16 * 32 = 512 bits)
 * - 端口: 1读 (AXI Master) + 1写 (VPU)
 * * 数据存储策略:
 * - VPU 写入的是对齐后的列向量 (Column-Major)。
 * - AXI Master 读取列向量，然后在接口模块内部进行转置。
 */
module output_buffer #(
    parameter int DATA_WIDTH           = 32,   // 固定为 32 (int32)
    parameter int SYSTOLIC_ARRAY_WIDTH = 16,   // 阵列尺寸 (W)
    parameter int ADDR_WIDTH           = 10    // 存储深度 1024 行/列向量
)(
    input logic clk,

    // ========================================================================
    // 写端口 (Port W) 
    // 来源: VPU (经过 De-skew 对齐后)
    // ========================================================================
    input logic [ADDR_WIDTH-1:0] wr_addr, // 来自 Control Unit
    input logic                  wr_en,   // 来自 tpu_core 的 aligned_wr_valid
    input logic [DATA_WIDTH-1:0] wr_data [SYSTOLIC_ARRAY_WIDTH], // 来自 tpu_core

    // ========================================================================
    // 读端口 (Port R)
    // 目标: AXI Master (读取 D 矩阵以发送到 DDR)
    // ========================================================================
    input logic [ADDR_WIDTH-1:0]  rd_addr, // 来自 AXI Master FSM
    input logic                   rd_en,   // 来自 AXI Master FSM
    output logic [DATA_WIDTH-1:0] rd_data [SYSTOLIC_ARRAY_WIDTH]  // 数组接口
);

    // ------------------------------------------------------------------------
    // 1. 存储核心定义
    // ------------------------------------------------------------------------
    localparam TOTAL_WIDTH = DATA_WIDTH * SYSTOLIC_ARRAY_WIDTH;
    
    // 推断 Block RAM / ASIC SRAM Macro (1R1W)
    logic [TOTAL_WIDTH-1:0] mem [0 : (2**ADDR_WIDTH)-1];

    // ------------------------------------------------------------------------
    // 2. 写逻辑 (Packing & Write)
    // ------------------------------------------------------------------------
    logic [TOTAL_WIDTH-1:0] wr_data_packed;

    // 将 Unpacked Array 打包成 Packed Vector
    always_comb begin
        for (int i = 0; i < SYSTOLIC_ARRAY_WIDTH; i++) begin
            wr_data_packed[(i+1)*DATA_WIDTH-1 -: DATA_WIDTH] = wr_data[i];
        end
    end

    // 同步写
    always_ff @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_data_packed;
        end
    end

    // ------------------------------------------------------------------------
    // 3. 读逻辑 (Read)
    // ------------------------------------------------------------------------
    logic [TOTAL_WIDTH-1:0] q_packed;

    // 同步读 (读出数据有 1 cycle 延迟)
    always_ff @(posedge clk) begin
        if (rd_en) begin
            q_packed <= mem[rd_addr];
        end
    end

    // ------------------------------------------------------------------------
    // 4. 输出解包逻辑 (Unpacking)
    // ------------------------------------------------------------------------
    // 将读出的长向量拆回数组形式
    always_comb begin
        for (int i = 0; i < SYSTOLIC_ARRAY_WIDTH; i++) begin
            rd_data[i] = q_packed[(i+1)*DATA_WIDTH-1 -: DATA_WIDTH];
        end
    end

endmodule
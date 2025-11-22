`timescale 1ns/1ps
`default_nettype none

/**
 * 模块名: input_buffer
 * 功能: 片上输入缓冲区 (SRAM)
 * 架构: 
 * - 深度: 2^ADDR_WIDTH (默认 1024)
 * - 宽度: SYSTOLIC_ARRAY_WIDTH * DATA_WIDTH (默认 16 * 32 = 512 bits)
 * - 端口: 3读 (A/B/C) + 1写 (Host)
 * * 数据存储策略:
 * - 物理存储单元固定为 32-bit。
 * - int8 数据 (Weight/Input) 存储在 [7:0]，读取后由外部模块截断。
 * - int32 数据 (Bias) 使用完整的 [31:0]。
 */
module input_buffer #(
    parameter int DATA_WIDTH           = 32,   // 固定为 32 以支持 int32
    parameter int SYSTOLIC_ARRAY_WIDTH = 16,   // 阵列尺寸 (W)
    parameter int ADDR_WIDTH           = 10    // 存储深度 1024 行向量
)(
    input logic clk,

    // ========================================================================
    // 写端口 (Port W_Host) 
    // 来源: AXI Slave (Host 写入初始数据 A, B, C)
    // ========================================================================
    input logic [ADDR_WIDTH-1:0] host_wr_addr,
    input logic                  host_wr_en,
    input logic [DATA_WIDTH-1:0] host_wr_data [SYSTOLIC_ARRAY_WIDTH], // 数组接口

    // ========================================================================
    // 读端口 A (Port A)
    // 目标: Systolic Array Top (输入 A)
    // ========================================================================
    input logic [ADDR_WIDTH-1:0]  rd_addr_a,
    input logic                   rd_en_a,
    output logic signed [DATA_WIDTH-1:0] rd_data_a [SYSTOLIC_ARRAY_WIDTH], 

    // ========================================================================
    // 读端口 B (Port B)
    // 目标: Systolic Array Left (权重 B) -> 经过 Skew Buffer
    // ========================================================================
    input logic [ADDR_WIDTH-1:0]  rd_addr_b,
    input logic                   rd_en_b,
    output logic signed [DATA_WIDTH-1:0] rd_data_b [SYSTOLIC_ARRAY_WIDTH], 

    // ========================================================================
    // 读端口 C (Port C)
    // 目标: VPU (偏置 C)
    // ========================================================================
    input logic [ADDR_WIDTH-1:0]  rd_addr_c,
    input logic                   rd_en_c,
    output logic signed [DATA_WIDTH-1:0] rd_data_c [SYSTOLIC_ARRAY_WIDTH]  
);

    // ------------------------------------------------------------------------
    // 1. 存储核心定义
    // ------------------------------------------------------------------------
    localparam TOTAL_WIDTH = DATA_WIDTH * SYSTOLIC_ARRAY_WIDTH;
    
    // 推断 Block RAM / ASIC SRAM Macro
    logic [TOTAL_WIDTH-1:0] mem [0 : (2**ADDR_WIDTH)-1];

    // ------------------------------------------------------------------------
    // 2. 写逻辑 (Packing & Write)
    // ------------------------------------------------------------------------
    logic [TOTAL_WIDTH-1:0] wr_data_packed;

    always_comb begin
        for (int i = 0; i < SYSTOLIC_ARRAY_WIDTH; i++) begin
            wr_data_packed[(i+1)*DATA_WIDTH-1 -: DATA_WIDTH] = host_wr_data[i];
        end
    end

    // 同步写
    always_ff @(posedge clk) begin
        if (host_wr_en) begin
            mem[host_wr_addr] <= wr_data_packed;
        end
    end

    // ------------------------------------------------------------------------
    // 3. 读逻辑 (多端口)
    // ------------------------------------------------------------------------
    logic [TOTAL_WIDTH-1:0] q_a_packed;
    logic [TOTAL_WIDTH-1:0] q_b_packed;
    logic [TOTAL_WIDTH-1:0] q_c_packed;

    // 同步读 (读出数据有 1 cycle 延迟)
    always_ff @(posedge clk) begin
        if (rd_en_a) q_a_packed <= mem[rd_addr_a];
        if (rd_en_b) q_b_packed <= mem[rd_addr_b];
        if (rd_en_c) q_c_packed <= mem[rd_addr_c];
    end

    // ------------------------------------------------------------------------
    // 4. 输出解包逻辑 (Unpacking)
    // ------------------------------------------------------------------------
    always_comb begin
        for (int i = 0; i < SYSTOLIC_ARRAY_WIDTH; i++) begin
            rd_data_a[i] = q_a_packed[(i+1)*DATA_WIDTH-1 -: DATA_WIDTH];
            rd_data_b[i] = q_b_packed[(i+1)*DATA_WIDTH-1 -: DATA_WIDTH];
            rd_data_c[i] = q_c_packed[(i+1)*DATA_WIDTH-1 -: DATA_WIDTH];
        end
    end

endmodule
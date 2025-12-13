`timescale 1ns/1ps
`default_nettype none

/**
 * 模块名: unified_buffer
 * 功能: 片上统一缓冲区 (SRAM)
 * 架构: 
 * - 深度: 2^ADDR_WIDTH (默认 1024)
 * - 宽度: SYSTOLIC_ARRAY_WIDTH * DATA_WIDTH (默认 16 * 32 = 512 bits)
 * - 端口: 3读 (A/B/C) + 1写 (W)
 * * 数据存储策略:
 * - 物理存储单元固定为 32-bit。
 * - int8 数据 (Weight/Input) 存储在 [7:0]，读取后由外部模块截断。 // 现在更改了，写入的时候就进行拆分，由axi_full_slave_if完成
 * - int32 数据 (Bias/Result) 使用完整的 [31:0]。
 */
module unified_buffer #(
    parameter int DATA_WIDTH           = 32,   // 固定为 32 以支持 int32
    parameter int SYSTOLIC_ARRAY_WIDTH = 16,   // 阵列尺寸 (W)
    parameter int ADDR_WIDTH           = 10    // 存储深度 1024 行向量
)(
    input logic clk,

    // ========================================================================
    // 写端口 (Port W) 
    // 来源: 
    //   1. AXI Slave (Host 写入初始数据 A, B, C)
    //   2. VPU (写回计算结果 D)
    // 注意: 需要在外部 (tpu_top) 通过仲裁器决定谁来写
    // ========================================================================
    input logic [ADDR_WIDTH-1:0] wr_addr,
    input logic                  wr_en,
    input logic [DATA_WIDTH-1:0] wr_data [SYSTOLIC_ARRAY_WIDTH], // 数组接口

    // ========================================================================
    // 读端口 A (Port A)
    // 目标: Systolic Array Top (权重 A)
    // ========================================================================
    input logic [ADDR_WIDTH-1:0]  rd_addr_a,
    input logic                   rd_en_a,
    output logic [DATA_WIDTH-1:0] rd_data_a [SYSTOLIC_ARRAY_WIDTH], 

    // ========================================================================
    // 读端口 B (Port B)
    // 目标: Systolic Array Left (输入 B) -> 经过 Skew Buffer
    // ========================================================================
    input logic [ADDR_WIDTH-1:0]  rd_addr_b,
    input logic                   rd_en_b,
    output logic [DATA_WIDTH-1:0] rd_data_b [SYSTOLIC_ARRAY_WIDTH], 

    // ========================================================================
    // 读端口 C (Port C)
    // 目标: VPU (偏置 C)
    // 复用: AXI Master (读取结果 D 到 DDR) 时也可以复用此端口或 Port A
    // ========================================================================
    input logic [ADDR_WIDTH-1:0]  rd_addr_c,
    input logic                   rd_en_c,
    output logic [DATA_WIDTH-1:0] rd_data_c [SYSTOLIC_ARRAY_WIDTH]  
);

    // ------------------------------------------------------------------------
    // 1. 存储核心定义
    // ------------------------------------------------------------------------
    // 计算总位宽: 16 * 32 = 512 bits
    localparam TOTAL_WIDTH = DATA_WIDTH * SYSTOLIC_ARRAY_WIDTH;
    
    // 定义存储器阵列 (Block RAM)
    // 这种定义方式通常能被 FPGA 综合工具推断为 BRAM
    /*
    *ASIC 综合：
    *初期/综合前：您可以使用这段代码进行功能验证。
    *后端/流片前：ASIC 工具（如 Design Compiler）不会把这段代码变成“BRAM”。它可能会试图用成千上万个触发器（Flip-Flops）来搭建这个内存，这会导致面积爆炸且布线无法通过。
    *正确做法：在 ASIC 流程的后期，您需要用 Memory Compiler（如 TSMC/SMIC 提供的工具） 生成一个真正的 SRAM 硬核 (Hard Macro)（通常是 .lib 和 .lef 文件），然后写一个简单的 Wrapper 模块来替换掉这段 logic mem[] 代码。
    *结论： 现阶段保留这段代码完全没问题，它是您的 Golden Model。但在做后端布局布线之前，您需要将其替换为工艺厂提供的 SRAM Macro 实例化代码。
    */
    logic [TOTAL_WIDTH-1:0] mem [0 : (2**ADDR_WIDTH)-1];

    // ------------------------------------------------------------------------
    // 2. 写逻辑 (Packing & Write)
    // ------------------------------------------------------------------------
    // 我们需要将输入的 Unpacked Array (便于连接) 打包成 Packed Vector (便于存储)
    logic [TOTAL_WIDTH-1:0] wr_data_packed;

    always_comb begin
        for (int i = 0; i < SYSTOLIC_ARRAY_WIDTH; i++) begin
            // 将数组切片映射到长向量
            // data[0] 对应最低位块, data[15] 对应最高位块
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
    // 从内存读出的是 Packed Vector
    logic [TOTAL_WIDTH-1:0] q_a_packed;
    logic [TOTAL_WIDTH-1:0] q_b_packed;
    logic [TOTAL_WIDTH-1:0] q_c_packed;

    // 同步读 (标准 BRAM 行为，读出数据有 1 cycle 延迟)
    always_ff @(posedge clk) begin
        if (rd_en_a) q_a_packed <= mem[rd_addr_a];
        if (rd_en_b) q_b_packed <= mem[rd_addr_b];
        if (rd_en_c) q_c_packed <= mem[rd_addr_c];
    end

    // ------------------------------------------------------------------------
    // 4. 输出解包逻辑 (Unpacking)
    // ------------------------------------------------------------------------
    // 将读出的长向量拆回数组形式
    always_comb begin
        for (int i = 0; i < SYSTOLIC_ARRAY_WIDTH; i++) begin
            rd_data_a[i] = q_a_packed[(i+1)*DATA_WIDTH-1 -: DATA_WIDTH];
            rd_data_b[i] = q_b_packed[(i+1)*DATA_WIDTH-1 -: DATA_WIDTH];
            rd_data_c[i] = q_c_packed[(i+1)*DATA_WIDTH-1 -: DATA_WIDTH];
        end
    end


endmodule
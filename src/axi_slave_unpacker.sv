`timescale 1ns/1ps
`default_nettype none

/**
 * 模块名: axi_slave_unpacker
 * 功能: AXI4 Slave 写数据解包器 -> SRAM 写入
 * 特性:
 * 1. 接收 AXI 写请求，将数据解包并写入 Input Buffer
 * 2. Gearbox: 适配 AXI 位宽 (e.g., 64b) 到 SRAM 位宽 (512b)
 * 3. Padding: 
 * - cfg_data_type_is_int32 = 0 (A/B): 1 Byte -> 32 Bit (Zero Padded)
 * - cfg_data_type_is_int32 = 1 (C)  : 4 Byte -> 32 Bit (Passthrough)
 */
module axi_slave_unpacker #(
    parameter int AXI_DATA_WIDTH   = 64,    // 外部总线宽度 (支持 32, 64, 128, 256)
    parameter int SRAM_DATA_WIDTH  = 32,    // 内部存储单元宽度
    parameter int ARRAY_WIDTH      = 16,    // 阵列宽度 (16个单元)
    parameter int ADDR_WIDTH       = 10     // SRAM 地址深度
)(
    input logic clk,
    input logic rst,

    // --- 配置信号 ---
    // 0: Int8 Mode (补零), 1: Int32 Mode (直通)
    // 该信号需由 Top Level 根据地址空间或寄存器驱动
    input logic cfg_data_type_is_int32, 

    // --- AXI4 Slave Interface (Write Channels Only) ---
    // 1. Write Address Channel
    input  logic [31:0]             awaddr,
    input  logic [7:0]              awlen,  // Burst Length: 0=1 beat
    input  logic [2:0]              awsize, // Burst Size: bytes in beat
    input  logic [1:0]              awburst,// Burst Type
    input  logic                    awvalid,
    output logic                    awready,
    
    // 2. Write Data Channel
    input  logic [AXI_DATA_WIDTH-1:0] wdata,
    input  logic [AXI_DATA_WIDTH/8-1:0] wstrb, // (Simplified: Assumed all valid or ignored)
    input  logic                      wlast,
    input  logic                      wvalid,
    output logic                      wready,
    
    // 3. Write Response Channel
    output logic [1:0]              bresp,
    output logic                    bvalid,
    input  logic                    bready,

    // --- To Input Buffer (SRAM Interface) ---
    output logic [ADDR_WIDTH-1:0]      host_wr_addr,
    output logic                       host_wr_en,
    output logic [SRAM_DATA_WIDTH-1:0] host_wr_data [ARRAY_WIDTH] // 512-bit unpacked
);

    // ========================================================================
    // 1. 常量计算
    // ========================================================================
    localparam ROW_BITS = SRAM_DATA_WIDTH * ARRAY_WIDTH; // 16 * 32 = 512 bits
    localparam ROW_BYTES = ROW_BITS / 8;                 // 64 Bytes per row
    
    // 计算 AXI Beat 中包含的有效元素数量
    // Int8 模式: 1 Byte = 1 Element
    localparam ELEMS_PER_BEAT_INT8  = AXI_DATA_WIDTH / 8;
    // Int32 模式: 4 Bytes = 1 Element
    localparam ELEMS_PER_BEAT_INT32 = AXI_DATA_WIDTH / 32;

    // ========================================================================
    // 2. 状态机定义
    // ========================================================================
    typedef enum logic [1:0] {
        IDLE,
        W_DATA,
        B_RESP
    } state_t;

    state_t state;

    // ========================================================================
    // 3. 内部信号
    // ========================================================================
    logic [ADDR_WIDTH-1:0] current_row_addr;
    
    // 行缓冲 (Row Buffer)
    // 我们将暂存解包后的数据，直到凑满一行 (16个元素)
    logic [SRAM_DATA_WIDTH-1:0] row_buffer [ARRAY_WIDTH]; 
    logic [4:0]                 elem_count; // 0 to 16
    
    // 握手信号逻辑
    logic aw_handshake;
    logic w_handshake;
    logic b_handshake;

    assign aw_handshake = awvalid && awready;
    assign w_handshake  = wvalid && wready;
    assign b_handshake  = bvalid && bready;

    // 简单的地址解码: 忽略低6位 (64字节对齐)，取高位作为 SRAM 行地址
    // 注意: 这里假设 Host 写入是 64-byte 对齐的，或者我们只关心行索引
    wire [ADDR_WIDTH-1:0] aw_row_index = awaddr[ADDR_WIDTH+6-1 : 6];

    // ========================================================================
    // 4. 主状态机
    // ========================================================================
    
    // AXI Ready 信号生成
    assign awready = (state == IDLE);
    assign wready  = (state == W_DATA);
    assign bvalid  = (state == B_RESP);
    assign bresp   = 2'b00; // OKAY

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            current_row_addr <= 0;
            elem_count <= 0;
            host_wr_en <= 0;
            host_wr_addr <= 0;
            // Reset buffer
            for(int i=0; i<ARRAY_WIDTH; i++) row_buffer[i] <= '0;
        end else begin
            // 默认脉冲复位
            host_wr_en <= 0;

            case (state)
                IDLE: begin
                    elem_count <= 0; // 新事务开始，重置缓冲区计数
                    if (awvalid) begin
                        // 锁存起始地址
                        current_row_addr <= aw_row_index;
                        state <= W_DATA;
                    end
                end

                W_DATA: begin
                    if (wvalid) begin
                        // --- 数据解包与填充逻辑 ---
                        // 仅当握手成功时执行
                        
                        logic [4:0] next_count;
                        int elems_added;
                        logic [7:0] current_byte; // 声明移到这里

                        elems_added = 0; // 临时变量

                        if (!cfg_data_type_is_int32) begin
                            // === Int8 Mode (Padding) ===
                            // 输入: AXI_DATA_WIDTH (e.g. 64 bits = 8 bytes)
                            // 动作: 取出每个字节，补零，填入 row_buffer
                            for (int i = 0; i < ELEMS_PER_BEAT_INT8; i++) begin
                                if ((elem_count + i) < ARRAY_WIDTH) begin
                                    // Extract byte, Zero Extend to 32b
                                    
                                    // 1. 提取当前字节
                                    current_byte = wdata[i*8 +: 8];                            
                                    // 拼接: {24个符号位, 8位数据}
                                    // {{24{current_byte[7]}}, current_byte}
                                    row_buffer[elem_count + i] <= {{24{current_byte[7]}}, current_byte};
                                end
                            end
                            elems_added = ELEMS_PER_BEAT_INT8;
                        end else begin
                            // === Int32 Mode (Passthrough) ===
                            // 输入: AXI_DATA_WIDTH (e.g. 64 bits = 2 words)
                            // 动作: 取出每个字，填入 row_buffer
                            for (int i = 0; i < ELEMS_PER_BEAT_INT32; i++) begin
                                if ((elem_count + i) < ARRAY_WIDTH) begin
                                    row_buffer[elem_count + i] <= wdata[i*32 +: 32];
                                end
                            end
                            elems_added = ELEMS_PER_BEAT_INT32;
                        end

                        // 更新计数
                        // 注意: 这里有一个边界情况，如果 elems_added 超过了剩余空间
                        // 简单起见，我们假设 Host 传输是对齐的 (Block Aligned)

                        next_count = elem_count + 5'(elems_added);

                        // --- 写入 SRAM 判断 ---
                        // 条件 1: Buffer 满了 (>= 16)
                        // 条件 2: 这是最后一个 Beat (WLAST)，即使没满也要把剩下的刷进去
                        if (next_count >= ARRAY_WIDTH || wlast) begin
                            host_wr_en   <= 1'b1;
                            host_wr_addr <= current_row_addr;
                            
                            // 输出数据连线 (将在下一拍生效，实际上 host_wr_data 是 wire)
                            // 这里需要注意：row_buffer 是 reg，更新是在时钟沿。
                            // host_wr_data 需要是组合逻辑或者我们在下一拍发出 en。
                            // 当前设计: host_wr_en 是寄存器输出，下一拍有效。
                            // row_buffer 在这一拍更新。
                            // 所以下一拍 SRAM 采样时，row_buffer 已经是更新后的满数据。
                            // 地址自增
                            current_row_addr <= current_row_addr + 1'b1;
                            
                            // 重置计数器 (为下一行准备)
                            // 如果 WLAST，则彻底清零；否则可能是刚好满行，准备接收下一行
                            // (如果 AXI 带宽很大，一次 Beat 可能跨越两行，这里暂不支持跨行 Beat)
                            // 我们假设 AXI Beat 不会跨越 SRAM 行边界 (64 Byte boundary)
                            elem_count <= 0; 
                        end else begin
                            // 还没满，继续积累
                            elem_count <= next_count;
                        end

                        // --- 状态跳转 ---
                        if (wlast) begin
                            state <= B_RESP;
                        end
                    end
                end

                B_RESP: begin
                    if (bready) begin
                        state <= IDLE;
                    end
                end
            endcase
        end
    end

    // ========================================================================
    // 5. 输出数据连线
    // ========================================================================
    // host_wr_data 直接连接到 row_buffer
    // 注意：在 host_wr_en 拉高的那一拍，row_buffer 必须已经稳定
    // 由于我们在 W_DATA 状态下更新 row_buffer，且 host_wr_en 也是在该状态下置 1 (下一拍有效)
    // 所以时序是对齐的：SRAM 在 host_wr_en 为 1 的时钟上升沿采样，此时 row_buffer 是满的。
    
    genvar k;
    generate
        for (k = 0; k < ARRAY_WIDTH; k++) begin : out_map
            assign host_wr_data[k] = row_buffer[k];
        end
    endgenerate

endmodule
`timescale 1ns/1ps
`default_nettype none

/**
 * 模块名: axi_master_packer
 * 功能: AXI4 Master 写数据打包器 (SRAM -> DDR)
 * 描述:
 * - 接收 start_dump 脉冲后，从 Output Buffer 读取 M 行数据
 * - 将 512-bit SRAM 数据拆解为 AXI Beat (例如 64-bit)
 * - 发起 AXI Write Burst 将数据写入 DDR
 */
module axi_master_packer #(
    parameter int AXI_DATA_WIDTH   = 64,    // 外部总线宽度
    parameter int SRAM_DATA_WIDTH  = 32,    // 内部元素宽度 (int32)
    parameter int ARRAY_WIDTH      = 16,    // 阵列宽度
    parameter int ADDR_WIDTH       = 10     // SRAM 地址深度
)(
    input logic clk,
    input logic rst,

    // --- Control Interface (From APB & Top) ---
    input logic        start_dump,      // Pulse to start transaction
    output logic       dump_done_irq,   // Interrupt when done
    
    // Configuration Registers
    input logic [63:0] reg_ddr_addr,    // Base address in DDR
    input logic [31:0] reg_m_len,       // Number of rows to dump
    input logic [31:0] reg_n_len,       // Number of valid columns (affects burst len)
    input logic [31:0] reg_addr_d,      // Start address in Output Buffer

    // --- SRAM Interface (Read from Output Buffer) ---
    output logic [ADDR_WIDTH-1:0]      rd_addr,
    output logic                       rd_en,
    input  logic [SRAM_DATA_WIDTH-1:0] rd_data [ARRAY_WIDTH], // 512-bit input

    // --- AXI4 Master Interface (Write Only) ---
    // 1. Write Address
    output logic [31:0]             awaddr,
    output logic [7:0]              awlen,
    output logic [2:0]              awsize,
    output logic [1:0]              awburst,
    output logic                    awvalid,
    input  logic                    awready,
    
    // 2. Write Data
    output logic [AXI_DATA_WIDTH-1:0] wdata,
    output logic [AXI_DATA_WIDTH/8-1:0] wstrb,
    output logic                      wlast,
    output logic                      wvalid,
    input  logic                      wready,
    
    // 3. Write Response
    input  logic [1:0]              bresp,
    input  logic                    bvalid,
    output logic                    bready
);

    // ========================================================================
    // 1. 常量与计算
    // ========================================================================
    localparam TOTAL_SRAM_BITS = SRAM_DATA_WIDTH * ARRAY_WIDTH; // 512 bits
    
    // 计算每个 SRAM 行需要多少个 AXI Beats
    // 假设: AXI_DATA_WIDTH = 64, SRAM_ROW = 512 bits (64 bytes)
    // BEATS_PER_ROW = 512 / 64 = 8
    localparam BEATS_PER_FULL_ROW = TOTAL_SRAM_BITS / AXI_DATA_WIDTH;

    // ========================================================================
    // 2. 状态机定义
    // ========================================================================
    typedef enum logic [2:0] {
        IDLE,
        PRE_READ,   // 发出 SRAM 读请求
        WAIT_SRAM,  // 等待 SRAM 数据返回
        AXI_AW,     // 发送写地址
        AXI_W,      // 发送写数据 (Burst)
        AXI_B,      // 等待写响应
        CHECK_DONE  // 检查是否完成所有行
    } state_t;

    state_t state;

    // ========================================================================
    // 3. 内部信号
    // ========================================================================
    logic [31:0]           current_ddr_addr;
    logic [ADDR_WIDTH-1:0] current_sram_addr;
    logic [31:0]           rows_processed;
    
    // Data Buffer (Capture SRAM output)
    logic [TOTAL_SRAM_BITS-1:0] data_buffer;
    
    // Burst Counter
    logic [7:0] beat_cnt;
    logic [7:0] target_beats; // 根据 N_LEN 动态计算

    // AXI Constants
    assign awsize  = 3'b011; // 8 bytes (Assume 64-bit bus)
    assign awburst = 2'b01;  // INCR
    assign wstrb   = '1;     // All bytes valid
    
    // ========================================================================
    // 4. 主逻辑
    // ========================================================================
    
    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            rd_en <= 0;
            rd_addr <= 0;
            awvalid <= 0;
            wvalid <= 0;
            wlast <= 0;
            bready <= 0;
            dump_done_irq <= 0;
            
            current_ddr_addr <= 0;
            current_sram_addr <= 0;
            rows_processed <= 0;
            data_buffer <= 0;
            beat_cnt <= 0;
            target_beats <= 0;
        end else begin
            // 默认信号清除
            rd_en <= 0;
            dump_done_irq <= 0;

            case (state)
                IDLE: begin
                    if (start_dump) begin
                        current_ddr_addr  <= reg_ddr_addr[31:0]; // Simplification: 32-bit addr used
                        current_sram_addr <= reg_addr_d[ADDR_WIDTH-1:0];
                        rows_processed    <= 0;
                        state <= PRE_READ;
                    end
                end

                PRE_READ: begin
                    // 发起 SRAM 读请求
                    rd_en   <= 1'b1;
                    rd_addr <= current_sram_addr;
                    state   <= WAIT_SRAM;
                end

                WAIT_SRAM: begin
                    // SRAM 有 1 周期延迟，这里等待数据到达
                    // 在这个周期的末尾（下个时钟沿），数据会出现在 rd_data 端口
                    // 我们可以在这里计算 Burst Length
                    
                    // 动态计算 Burst Length:
                    // Bytes = N_LEN * 4. Beats = Bytes / 8.
                    // Example: N=16 -> 64 Bytes -> 8 Beats -> AWLEN=7
                    // Example: N=8  -> 32 Bytes -> 4 Beats -> AWLEN=3
                    // Formula: (N * 4 * 8) / AXI_WIDTH = (N * 32) / AXI_WIDTH
                    
                    // 为简化逻辑，我们假设总是搬运整行 (或者根据 N 优化)
                    // 这里实现简单的全行搬运 (Full Row Dump)
                    // 如果 N < 16，DDR 里会有一些无效数据，但软件可以忽略
                    target_beats <= BEATS_PER_FULL_ROW[7:0]; 
                    
                    state <= AXI_AW;
                end

                AXI_AW: begin
                    // 锁存 SRAM 数据到内部 Buffer
                    // 注意：rd_data 是 unpacked array，需要 pack 起来方便移位
                    for (int i=0; i<ARRAY_WIDTH; i++) begin
                        data_buffer[(i+1)*32-1 -: 32] <= rd_data[i];
                    end

                    // 发起 AXI 写地址请求
                    awvalid <= 1'b1;
                    awaddr  <= current_ddr_addr;
                    awlen   <= target_beats - 1'b1; // AXI len is beats-1
                    
                    if (awvalid && awready) begin
                        awvalid <= 1'b0;
                        state <= AXI_W;
                        beat_cnt <= 0;
                    end
                end

                AXI_W: begin
                    wvalid <= 1'b1;
                    
                    // Data Selection (Gearbox)
                    // 取最低的 AXI_DATA_WIDTH 位发送
                    // 假设 AXI=64, SRAM=512. 
                    // Beat 0: data[63:0]
                    // Beat 1: data[127:64] (Shifted in logic below)
                    wdata <= data_buffer[AXI_DATA_WIDTH-1:0];
                    
                    if (beat_cnt == target_beats - 1'b1) begin
                        wlast <= 1'b1;
                    end else begin
                        wlast <= 1'b0;
                    end

                    if (wvalid && wready) begin
                        // 移位 Buffer，准备下一个 Beat
                        data_buffer <= data_buffer >> AXI_DATA_WIDTH;
                        beat_cnt <= beat_cnt + 1'b1;
                        
                        if (wlast) begin
                            wvalid <= 1'b0;
                            wlast  <= 1'b0;
                            state  <= AXI_B;
                        end
                    end
                end

                AXI_B: begin
                    bready <= 1'b1;
                    if (bvalid && bready) begin
                        bready <= 1'b0;
                        state <= CHECK_DONE;
                    end
                end

                CHECK_DONE: begin
                    // 更新地址和计数
                    // DDR 地址增加 64 Bytes (0x40)
                    current_ddr_addr <= current_ddr_addr + 32'h40; 
                    current_sram_addr <= current_sram_addr + 1'b1;
                    rows_processed <= rows_processed + 1'b1;
                    
                    // 检查是否完成所有行
                    if (rows_processed + 1'b1 >= reg_m_len) begin
                        dump_done_irq <= 1'b1; // 触发中断
                        state <= IDLE;
                    end else begin
                        state <= PRE_READ; // 处理下一行
                    end
                end
            endcase
        end
    end

endmodule
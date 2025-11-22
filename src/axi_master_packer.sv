`timescale 1ns/1ps
`default_nettype none

module axi_master_packer #(
    parameter int AXI_DATA_WIDTH   = 64,    
    parameter int SRAM_DATA_WIDTH  = 32,    
    parameter int ARRAY_WIDTH      = 16,    
    parameter int ADDR_WIDTH       = 10     
)(
    input logic clk,
    input logic rst,

    // Control
    input logic        start_dump,      
    output logic       dump_done_irq,   
    
    // Config
    input logic [63:0] reg_ddr_addr,    
    input logic [31:0] reg_m_len,       
    input logic [31:0] reg_n_len,       
    input logic [31:0] reg_addr_d,      

    // SRAM Read
    output logic [ADDR_WIDTH-1:0]      rd_addr,
    output logic                       rd_en,
    input  logic [SRAM_DATA_WIDTH-1:0] rd_data [ARRAY_WIDTH],  //vivado报错，需要加signed

    // AXI4 Master Write
    output logic [31:0]             awaddr,
    output logic [7:0]              awlen,
    output logic [2:0]              awsize,
    output logic [1:0]              awburst,
    output logic                    awvalid,
    input  logic                    awready,
    
    output logic [AXI_DATA_WIDTH-1:0] wdata,  // [修正] 改为 wire 驱动
    output logic [AXI_DATA_WIDTH/8-1:0] wstrb,
    output logic                      wlast,  // [修正] 改为 wire 驱动
    output logic                      wvalid,
    input  logic                      wready,
    
    input  logic [1:0]              bresp,
    input  logic                    bvalid,
    output logic                    bready
);

    localparam TOTAL_SRAM_BITS = SRAM_DATA_WIDTH * ARRAY_WIDTH; 
    localparam BEATS_PER_FULL_ROW = TOTAL_SRAM_BITS / AXI_DATA_WIDTH;

    typedef enum logic [2:0] {
        IDLE, PRE_READ, WAIT_SRAM, AXI_AW, AXI_W, AXI_B, CHECK_DONE
    } state_t;
    state_t state;

    logic [31:0]           current_ddr_addr;
    logic [ADDR_WIDTH-1:0] current_sram_addr;
    logic [31:0]           rows_processed;
    logic [TOTAL_SRAM_BITS-1:0] data_buffer;
    logic [7:0]            beat_cnt;
    logic [7:0]            target_beats; 

    // [修正] 组合逻辑驱动数据输出，消除时序滞后
    assign wdata   = data_buffer[AXI_DATA_WIDTH-1:0]; 
    assign wlast   = (beat_cnt == target_beats - 1'b1); 
    
    assign awsize  = 3'b011; 
    assign awburst = 2'b01;  
    assign wstrb   = '1;     

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            rd_en <= 0; rd_addr <= 0;
            awvalid <= 0; wvalid <= 0; bready <= 0;
            dump_done_irq <= 0;
            current_ddr_addr <= 0; current_sram_addr <= 0; rows_processed <= 0;
            data_buffer <= 0; beat_cnt <= 0; target_beats <= 0;
            awaddr <= 0; awlen <= 0;
        end else begin
            rd_en <= 0;
            dump_done_irq <= 0;

            case (state)
                IDLE: begin
                    if (start_dump) begin
                        current_ddr_addr  <= reg_ddr_addr[31:0];
                        current_sram_addr <= reg_addr_d[ADDR_WIDTH-1:0];
                        rows_processed    <= 0;
                        state <= PRE_READ;
                    end
                end

                PRE_READ: begin
                    rd_en   <= 1'b1;
                    rd_addr <= current_sram_addr;
                    state   <= WAIT_SRAM;
                end

                WAIT_SRAM: begin
                    // 等待数据并计算 Beat 数
                    target_beats <= BEATS_PER_FULL_ROW[7:0]; 
                    state <= AXI_AW;
                end

                AXI_AW: begin
                    // 锁存数据
                    for (int i=0; i<ARRAY_WIDTH; i++) begin
                        data_buffer[(i+1)*32-1 -: 32] <= rd_data[i];
                    end

                    awvalid <= 1'b1;
                    awaddr  <= current_ddr_addr;
                    awlen   <= target_beats - 1'b1;
                    
                    // 检查当前拍是否握手成功 (避免延迟)
                    // 但由于 awvalid 是寄存器输出，需要下一拍才能握手
                    // 这里使用标准逻辑：置位 -> 等待 ready
                    if (awvalid && awready) begin
                        awvalid <= 1'b0;
                        state <= AXI_W;
                        beat_cnt <= 0;
                        wvalid <= 1'b1; // 提前准备 W 通道
                    end
                end

                AXI_W: begin
                    wvalid <= 1'b1;
                    
                    if (wvalid && wready) begin
                        // 握手成功，移位 Buffer
                        data_buffer <= data_buffer >> AXI_DATA_WIDTH;
                        beat_cnt <= beat_cnt + 1'b1;
                        
                        // 检查是否是最后一个 Beat
                        // 注意：这里使用的是组合逻辑 wlast
                        if (wlast) begin
                            wvalid <= 1'b0;
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
                    current_ddr_addr <= current_ddr_addr + 32'h40; // 64 Bytes offset
                    current_sram_addr <= current_sram_addr + 1'b1;
                    rows_processed <= rows_processed + 1'b1;
                    
                    if (rows_processed + 1'b1 >= reg_m_len) begin
                        dump_done_irq <= 1'b1;
                        state <= IDLE;
                    end else begin
                        state <= PRE_READ;
                    end
                end
            endcase
        end
    end

endmodule
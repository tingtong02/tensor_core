`timescale 1ns/1ps

module tb_top_tpu_fixed_size;

    // 1. 参数与信号 (保持不变)
    parameter int AXI_DATA_WIDTH       = 64;
    parameter int SYSTOLIC_ARRAY_WIDTH = 16;
    parameter int DATA_WIDTH           = 8;
    parameter int ACCUM_WIDTH          = 32;
    parameter int ADDR_WIDTH           = 10;

    // Register Addresses
    localparam ADDR_CTRL       = 32'h00;
    localparam ADDR_STATUS     = 32'h04;
    localparam ADDR_M_LEN      = 32'h08;
    localparam ADDR_K_LEN      = 32'h0C;
    localparam ADDR_N_LEN      = 32'h10;
    localparam ADDR_ADDR_A     = 32'h14;
    localparam ADDR_ADDR_B     = 32'h18;
    localparam ADDR_ADDR_C     = 32'h1C;
    localparam ADDR_ADDR_D     = 32'h20;
    localparam ADDR_DDR_L      = 32'h24;
    localparam ADDR_DDR_H      = 32'h28;
    localparam ADDR_CMD_PUSH   = 32'h2C;

    logic clk, rst_n;
    
    // APB
    logic        psel, penable, pwrite;
    logic [31:0] paddr, pwdata, prdata;
    logic        pready, pslverr;

    // AXI Slave & Master Signals (Standard definitions)
    // ... (为了节省篇幅，这里省略具体的 wire 定义，与之前的 tb_top_tpu 一致) ...
    // 请直接复制之前 tb_top_tpu.sv 中的 AXI 信号声明和 DUT 实例化部分
    
    // --- 信号声明补全 ---
    logic [31:0] s_axi_awaddr, m_axi_awaddr;
    logic [7:0]  s_axi_awlen, m_axi_awlen;
    logic [2:0]  s_axi_awsize, m_axi_awsize;
    logic [1:0]  s_axi_awburst, m_axi_awburst;
    logic        s_axi_awvalid, s_axi_awready, m_axi_awvalid, m_axi_awready;
    logic [63:0] s_axi_wdata, m_axi_wdata;
    logic [7:0]  s_axi_wstrb, m_axi_wstrb;
    logic        s_axi_wlast, m_axi_wlast, s_axi_wvalid, s_axi_wready, m_axi_wvalid, m_axi_wready;
    logic [1:0]  s_axi_bresp, m_axi_bresp;
    logic        s_axi_bvalid, s_axi_bready, m_axi_bvalid, m_axi_bready;

    // DUT Instance
    top_tpu #(
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH), .SYSTOLIC_ARRAY_WIDTH(SYSTOLIC_ARRAY_WIDTH),
        .DATA_WIDTH(DATA_WIDTH), .ACCUM_WIDTH(ACCUM_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (.*); // SystemVerilog implicit connection

    // Clock
    initial begin clk=0; forever #5 clk=~clk; end

    // Tasks (APB Write/Read, AXI Write) - Copy form previous TB
    task apb_write(input [31:0] addr, input [31:0] data);
        @(negedge clk); psel=1; penable=0; pwrite=1; paddr=addr; pwdata=data;
        @(negedge clk); penable=1;
        @(negedge clk); psel=0; penable=0; pwrite=0;
    endtask

    task apb_poll_compute_done();
        logic [31:0] d;
        forever begin
            @(negedge clk); psel=1; penable=0; pwrite=0; paddr=ADDR_STATUS;
            @(negedge clk); penable=1;
            @(negedge clk); d=prdata; psel=0; penable=0;
            if(d[1]) break; // Bit 1 is compute done
            repeat(10) @(posedge clk);
        end
    endtask

    // 简化版 AXI Write Matrix (Uniform Value)
    task axi_write_uniform(input [31:0] addr, input int rows, input int val, input int is_int32);
        int beats = rows * (is_int32 ? 8 : 2);
        @(negedge clk);
        s_axi_awaddr=addr; s_axi_awlen=beats-1; s_axi_awsize=3; s_axi_awburst=1; s_axi_awvalid=1;
        do @(posedge clk); while(!s_axi_awready);
        @(negedge clk); s_axi_awvalid=0;
        
        for(int i=0; i<beats; i++) begin
            s_axi_wdata = (is_int32) ? {32'(val), 32'(val)} : {8{8'(val)}};
            s_axi_wstrb='1; s_axi_wlast=(i==beats-1); s_axi_wvalid=1;
            do @(posedge clk); while(!s_axi_wready);
            @(negedge clk);
        end
        s_axi_wvalid=0; s_axi_wlast=0; s_axi_bready=1;
        do @(posedge clk); while(!s_axi_bvalid);
        @(negedge clk); s_axi_bready=0;
    endtask

    // AXI Master Monitor
    logic [31:0] result_q [$];
    initial begin
        m_axi_awready=1; m_axi_wready=1; m_axi_bvalid=0;
        forever begin
            @(posedge clk);
            if(m_axi_wvalid && m_axi_wready) begin
                result_q.push_back(m_axi_wdata[31:0]);
                result_q.push_back(m_axi_wdata[63:32]);
            end
            if(m_axi_wlast && m_axi_wvalid) begin
                m_axi_bvalid<=1; @(posedge clk); m_axi_bvalid<=0;
            end
        end
    end

    // ========================================================================
    // Main Test: 验证统一尺寸下的 Mask 保持
    // ========================================================================
    initial begin
        rst_n=0; 
        s_axi_awvalid=0; s_axi_wvalid=0; s_axi_bready=0;
        #50; rst_n=1; #20;

        $display("=== Fixed Size Test Start ===");

        // 1. Configure (16x16)
        apb_write(ADDR_M_LEN, 16); apb_write(ADDR_K_LEN, 16); apb_write(ADDR_N_LEN, 16);
        apb_write(ADDR_ADDR_A, 0);
        apb_write(ADDR_ADDR_B, 16);
        apb_write(ADDR_ADDR_C, 512); // Offset 0x8000
        apb_write(ADDR_ADDR_D, 48);
        apb_write(ADDR_DDR_L, 32'h8000_0000);

        // 2. Load Data
        // A=1, B=2, C=5
        // D = (1*2)*16 + 5 = 37
        axi_write_uniform(32'h0000_0000, 16, 1, 0); // A
        axi_write_uniform(32'h0000_0400, 16, 2, 0); // B
        axi_write_uniform(32'h0000_8000, 16, 5, 1); // C (Int32)

        // 3. Start Compute
        apb_write(ADDR_CMD_PUSH, 1);
        $display("[TEST] Task Started...");

        // 4. Wait Done
        apb_poll_compute_done();
        $display("[TEST] Compute Done.");
        apb_write(ADDR_STATUS, 2); // Clear IRQ

        // 5. Start Dump
        apb_write(ADDR_CTRL, 2);
        $display("[TEST] Dump Started...");
        
        // Wait for data
        #2000; 

        // 6. Check
        if(result_q.size() != 256) $error("Missing Data! Got %0d", result_q.size());
        else begin
            int err=0;
            foreach(result_q[i]) if(result_q[i] !== 37) err++;
            
            if(err==0) $display("=== SUCCESS: All data correct (37) ===");
            else $display("=== FAIL: %0d errors. First: %0d ===", err, result_q[0]);
        end
        $finish;
    end

endmodule
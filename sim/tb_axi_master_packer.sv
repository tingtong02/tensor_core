`timescale 1ns/1ps

module tb_axi_master_packer;

    // ========================================================================
    // 1. 信号与参数
    // ========================================================================
    parameter int AXI_DATA_WIDTH   = 64;
    parameter int SRAM_DATA_WIDTH  = 32;
    parameter int ARRAY_WIDTH      = 16;
    parameter int ADDR_WIDTH       = 10;

    logic clk;
    logic rst;

    logic        start_dump;
    logic        dump_done_irq;
    
    logic [63:0] reg_ddr_addr;
    logic [31:0] reg_m_len;
    logic [31:0] reg_n_len;
    logic [31:0] reg_addr_d;

    logic [ADDR_WIDTH-1:0]      rd_addr;
    logic                       rd_en;
    logic [SRAM_DATA_WIDTH-1:0] rd_data [ARRAY_WIDTH];

    logic [31:0]             awaddr;
    logic [7:0]              awlen;
    logic [2:0]              awsize;
    logic [1:0]              awburst;
    logic                    awvalid;
    logic                    awready;
    
    logic [AXI_DATA_WIDTH-1:0] wdata;
    logic [AXI_DATA_WIDTH/8-1:0] wstrb;
    logic                      wlast;
    logic                      wvalid;
    logic                      wready;
    
    logic [1:0]              bresp;
    logic                    bvalid;
    logic                    bready;

    // ========================================================================
    // 2. DUT 实例化
    // ========================================================================
    axi_master_packer dut (.*);

    // ========================================================================
    // 3. 模拟组件
    // ========================================================================
    
    // --- Clock Gen ---
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // --- SRAM Model ---
    // 当 rd_en 拉高时，下一拍返回数据
    // 数据模式: data[i] = {Row_Idx, Col_Idx} (方便调试)
    always_ff @(posedge clk) begin
        if (rd_en) begin
            for(int i=0; i<ARRAY_WIDTH; i++) begin
                // 高16位是行地址，低16位是列索引
                rd_data[i] <= {16'(rd_addr), 16'(i)};
            end
        end
    end

    // --- AXI Slave BFM (Memory Controller) ---
    logic [31:0] expected_addr;
    int burst_cnt;
    
    initial begin
        awready = 0;
        wready = 0;
        bvalid = 0;
        bresp = 0;
        
        forever begin
            @(posedge clk);
            // 1. Handle Address Handshake
            if (awvalid && !awready) begin
                // Random delay
                repeat($urandom_range(0, 2)) @(posedge clk);
                awready <= 1;
                @(posedge clk);
                awready <= 0;
                $display("[AXI SLAVE] Got Write Addr: %h, Len: %d", awaddr, awlen);
            end

            // 2. Handle Write Data Handshake
            if (wvalid && !wready) begin
                repeat($urandom_range(0, 1)) @(posedge clk);
                wready <= 1;
                
                // 数据校验逻辑
                // 我们知道 SRAM 发出的数据是 {Row, Col}
                // Row 应该对应当前的 Burst 序号 (0, 1...)
                // Col 应该对应当前的 Beat (每 Beat 2 个 int32 -> 2 cols)
                // 略微复杂的校验留给肉眼看 Log，这里只打印
                
                @(posedge clk);
                $display("[AXI SLAVE] Got WDATA: %h (Last: %b)", wdata, wlast);
                wready <= 0;

                // 3. Handle Response (After Last)
                if (wlast) begin
                    repeat(2) @(posedge clk);
                    bvalid <= 1;
                    do begin
                        @(posedge clk);
                    end while (!bready);
                    bvalid <= 0;
                    $display("[AXI SLAVE] Sent Write Resp");
                end
            end
        end
    end

    // ========================================================================
    // 4. 主测试流程
    // ========================================================================
    initial begin
        rst = 1;
        start_dump = 0;
        reg_ddr_addr = 64'h1000_0000;
        reg_m_len = 0;
        reg_n_len = 16;
        reg_addr_d = 0;
        
        #100; rst = 0; #20;

        $display("=== Test Start: Dump 2 Rows ===");
        
        // 配置: 搬运 2 行
        reg_m_len = 2;
        reg_addr_d = 10; // Start from SRAM Row 10
        
        @(negedge clk);
        start_dump = 1;
        @(negedge clk);
        start_dump = 0;

        // 等待完成中断
        wait(dump_done_irq == 1);
        $display("=== Dump Done IRQ Received ===");
        
        #100;
        $finish;
    end

endmodule
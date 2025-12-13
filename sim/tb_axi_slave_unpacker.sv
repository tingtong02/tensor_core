`timescale 1ns/1ps

module tb_axi_slave_unpacker;

    // ========================================================================
    // 1. 参数与信号
    // ========================================================================
    parameter int AXI_DATA_WIDTH   = 64;
    parameter int SRAM_DATA_WIDTH  = 32;
    parameter int ARRAY_WIDTH      = 16;
    parameter int ADDR_WIDTH       = 10;

    logic clk;
    logic rst;
    logic cfg_data_type_is_int32;

    // AXI Write Channels
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

    // SRAM Interface
    logic [ADDR_WIDTH-1:0]      host_wr_addr;
    logic                       host_wr_en;
    logic [SRAM_DATA_WIDTH-1:0] host_wr_data [ARRAY_WIDTH];

    // ========================================================================
    // 2. DUT 实例化
    // ========================================================================
    axi_slave_unpacker #(
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .SRAM_DATA_WIDTH(SRAM_DATA_WIDTH),
        .ARRAY_WIDTH(ARRAY_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
        .clk(clk),
        .rst(rst),
        .cfg_data_type_is_int32(cfg_data_type_is_int32),
        
        .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid), .bready(bready),
        
        .host_wr_addr(host_wr_addr),
        .host_wr_en(host_wr_en),
        .host_wr_data(host_wr_data)
    );

    // ========================================================================
    // 3. 辅助任务 (AXI Master BFMs)
    // ========================================================================
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // 任务: 发送写地址
    task axi_send_addr(input [31:0] addr, input [7:0] len);
        @(negedge clk);
        awaddr  = addr;
        awlen   = len; // Burst Length = len + 1
        awsize  = 3'b011; // 8 bytes (64-bit)
        awburst = 2'b01; // INCR
        awvalid = 1;
        
        // Wait for handshake
        do begin
            @(posedge clk);
        end while (!awready);
        
        @(negedge clk);
        awvalid = 0;
    endtask

    // 任务: 发送写数据 (Burst Mode)
    // mode: 0=Int8 (1 byte inc), 1=Int32 (4 byte inc)
    task axi_send_data_burst(input int burst_len, input int start_val, input int mode);
        for (int i = 0; i <= burst_len; i++) begin
            @(negedge clk);
            wvalid = 1;
            wlast  = (i == burst_len);
            wstrb  = '1; // All valid
            
            // Construct 64-bit Data
            if (mode == 0) begin
                // Int8 Mode: Pack 8 bytes (val, val+1, ..., val+7)
                wdata = {
                    8'(start_val + i*8 + 7), 8'(start_val + i*8 + 6), 
                    8'(start_val + i*8 + 5), 8'(start_val + i*8 + 4),
                    8'(start_val + i*8 + 3), 8'(start_val + i*8 + 2), 
                    8'(start_val + i*8 + 1), 8'(start_val + i*8 + 0)
                };
            end else begin
                // Int32 Mode: Pack 2 words
                wdata = {
                    32'(start_val + i*2 + 1), 32'(start_val + i*2 + 0)
                };
            end

            // Wait for handshake
            do begin
                @(posedge clk);
            end while (!wready);
        end
        
        @(negedge clk);
        wvalid = 0;
        wlast  = 0;
    endtask

    // 任务: 接收写响应
    task axi_recv_resp();
        @(negedge clk);
        bready = 1;
        do begin
            @(posedge clk);
        end while (!bvalid);
        @(negedge clk);
        bready = 0;
    endtask

    // ========================================================================
    // 4. 主测试流程
    // ========================================================================
    initial begin
        // Init
        rst = 1; cfg_data_type_is_int32 = 0;
        awvalid = 0; wvalid = 0; bready = 0;
        awaddr = 0; awlen = 0; wdata = 0;
        
        #50; rst = 0; #20;

        $display("=== Test 1: Int8 Padding Mode (Single Row) ===");
        // 配置: Int8, Addr=0
        // 目标: 填满一行 SRAM (16个 int8)。
        // AXI Width=64bit (8 bytes/beat) -> 需要 2 beats (len=1)
        
        cfg_data_type_is_int32 = 0; 
        
        fork
            begin
                // AW Channel
                axi_send_addr(32'h0000_0000, 8'd1); 
            end
            begin
                // W Channel
                axi_send_data_burst(1, 1, 0); 
            end
            begin
                // B Channel
                axi_recv_resp();
            end
            begin
                // Monitor (Parallel Check)
                wait(host_wr_en == 1);
                #1; // [关键修复] 消除竞争
                
                $display("[SRAM WR] Addr: %h", host_wr_addr);
                
                // 检查地址
                if (host_wr_addr !== 0) $error("Address Mismatch! Expected 0");
                
                // 检查数据补零 (0x01 -> 0x00000001)
                if (host_wr_data[0] === 32'h0000_0001 && host_wr_data[1] === 32'h0000_0002) 
                    $display("[DATA PASS] Int8 0x01 correctly padded to 0x00000001");
                else
                    $error("[DATA FAIL] Padding incorrect. Got %h", host_wr_data[0]);
            end
        join

        @(posedge clk); // 间隔


        $display("=== Test 2: Int32 Passthrough Mode (Single Row) ===");
        // 配置: Int32, Addr=0x40 (64, 即第2行)
        // 目标: 填满一行 SRAM (16个 int32)。
        // AXI Width=64bit (2 words/beat) -> 需要 8 beats (len=7)
        
        cfg_data_type_is_int32 = 1;
        #20;

        fork
            begin
                axi_send_addr(32'h0000_0040, 8'd7); 
            end
            begin
                axi_send_data_burst(7, 100, 1); // Start val 100, mode 1
            end
            begin
                axi_recv_resp();
            end
            begin
                // Monitor
                wait(host_wr_en == 1);
                #1; // [关键修复]
                
                $display("[SRAM WR] Addr: %h", host_wr_addr);
                
                // 检查是否为 1 (第2行)
                if (host_wr_addr !== 1) $error("Address Mismatch! Expected 1 (Row 1)");

                // 检查数据透传
                if (host_wr_data[0] === 100 && host_wr_data[1] === 101) 
                    $display("[DATA PASS] Int32 Passthrough correct.");
                else
                    $error("[DATA FAIL] Data mismatch.");
            end
        join

        @(posedge clk);


        $display("=== Test 3: Burst Across Rows (Int8 Mode) ===");
        // 配置: Int8
        // 目标: 一次写 2 行 (32个元素)。
        // 需要 32 bytes / 8 bytes-per-beat = 4 beats (len=3)
        // 将会产生 2 次 host_wr_en 脉冲 (Row 2 和 Row 3)
        
        cfg_data_type_is_int32 = 0;
        #20;

        fork
            begin
                axi_send_addr(32'h0000_0080, 8'd3); 
            end
            begin
                axi_send_data_burst(3, 10, 0); 
            end
            begin
                axi_recv_resp();
            end
            begin
                // --- Burst Beat 1 ---
                wait(host_wr_en == 1);
                #1;
                $display("[SRAM WR BURST 1] Addr: %h (Expected 2)", host_wr_addr);
                if (host_wr_addr !== 2) $error("Burst Addr 1 Fail");
                
                // [关键修复]：必须等待当前脉冲结束 (变低)
                // 否则下一个 wait(en==1) 会立即触发 (Double Sampling)
                wait(host_wr_en == 0); 
                
                // --- Burst Beat 2 ---
                wait(host_wr_en == 1);
                #1;
                $display("[SRAM WR BURST 2] Addr: %h (Expected 3)", host_wr_addr);
                
                // 这里之前报错 Got 002，是因为重复采样了 Beat 1
                // 现在应该能正确采到 003
                if (host_wr_addr !== 3) $error("Burst Addr 2 Fail. Got: %h", host_wr_addr);
                
                @(posedge clk);
            end
        join

        $display("=== All Tests Finished ===");
        $finish;
    end

endmodule
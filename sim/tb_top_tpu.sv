`timescale 1ns/1ps

module tb_top_tpu;

    // ========================================================================
    // 1. 参数定义
    // ========================================================================
    parameter int AXI_DATA_WIDTH       = 64;
    parameter int SYSTOLIC_ARRAY_WIDTH = 16;
    parameter int DATA_WIDTH           = 8;
    parameter int ACCUM_WIDTH          = 32;
    parameter int ADDR_WIDTH           = 10;

    // ========================================================================
    // 2. 接口信号声明
    // ========================================================================
    logic clk;
    logic rst_n;

    // --- APB Interface ---
    logic        psel;
    logic        penable;
    logic        pwrite;
    logic [31:0] paddr;
    logic [31:0] pwdata;
    logic [31:0] prdata;
    logic        pready;
    logic        pslverr;

    // --- AXI4 Slave Interface (Host Write -> TPU) ---
    logic [31:0]             s_axi_awaddr;
    logic [7:0]              s_axi_awlen;
    logic [2:0]              s_axi_awsize;
    logic [1:0]              s_axi_awburst;
    logic                    s_axi_awvalid;
    logic                    s_axi_awready;
    logic [AXI_DATA_WIDTH-1:0] s_axi_wdata;
    logic [AXI_DATA_WIDTH/8-1:0] s_axi_wstrb;
    logic                      s_axi_wlast;
    logic                      s_axi_wvalid;
    logic                      s_axi_wready;
    logic [1:0]              s_axi_bresp;
    logic                    s_axi_bvalid;
    logic                    s_axi_bready;

    // --- AXI4 Master Interface (TPU -> DDR) ---
    logic [31:0]             m_axi_awaddr;
    logic [7:0]              m_axi_awlen;
    logic [2:0]              m_axi_awsize;
    logic [1:0]              m_axi_awburst;
    logic                    m_axi_awvalid;
    logic                    m_axi_awready;
    logic [AXI_DATA_WIDTH-1:0] m_axi_wdata;
    logic [AXI_DATA_WIDTH/8-1:0] m_axi_wstrb;
    logic                      m_axi_wlast;
    logic                      m_axi_wvalid;
    logic                      m_axi_wready;
    logic [1:0]              m_axi_bresp;
    logic                    m_axi_bvalid;
    logic                    m_axi_bready;

    // ========================================================================
    // 3. DUT 实例化
    // ========================================================================
    top_tpu #(
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .SYSTOLIC_ARRAY_WIDTH(SYSTOLIC_ARRAY_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),

        // APB
        .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr),
        .pwdata(pwdata), .prdata(prdata), .pready(pready), .pslverr(pslverr),

        // AXI Slave
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awlen(s_axi_awlen), .s_axi_awsize(s_axi_awsize),
        .s_axi_awburst(s_axi_awburst), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wlast(s_axi_wlast),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),

        // AXI Master
        .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready)
    );

    // ========================================================================
    // 4. 仿真环境设置
    // ========================================================================
    
    // 时钟生成 (100MHz)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // AXI Slave 默认值
    initial begin
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_bready = 0;
        s_axi_awaddr = 0; s_axi_wdata = 0;
    end

    // APB 默认值
    initial begin
        psel = 0; penable = 0; pwrite = 0; paddr = 0; pwdata = 0;
    end

    // ========================================================================
    // 5. APB 配置任务 (BFM)
    // ========================================================================
    task apb_write(input [31:0] addr, input [31:0] data);
        @(posedge clk);
        psel    <= 1;
        pwrite  <= 1;
        paddr   <= addr;
        pwdata  <= data;
        penable <= 0;
        @(posedge clk);
        penable <= 1;
        wait(pready);
        @(posedge clk);
        psel    <= 0;
        penable <= 0;
        pwrite  <= 0;
        $display("[%0t] [APB] Write Addr: %h, Data: %h", $time, addr, data);
    endtask

    // ========================================================================
    // 6. AXI Slave 写入任务 (BFM) - 用于加载 SRAM
    // ========================================================================
    
    // 向 SRAM 写入一行数据
    // mode: 0=Int8 (A/B), 1=Int32 (C)
    task axi_write_row(input [31:0] addr, input int val, input int active_lanes, input int mode);
        int beats;
        int bytes_per_elem;
        
        // 自动计算 Burst Length
        // SRAM Row = 16 elems. 
        // Int8 Mode: 16 * 1 Byte = 16 Bytes. AXI64 = 8 Bytes/beat. -> 2 Beats.
        // Int32 Mode: 16 * 4 Bytes = 64 Bytes. AXI64 = 8 Bytes/beat. -> 8 Beats.
        if (mode == 0) begin
            beats = 2; 
            bytes_per_elem = 1;
        end else begin
            beats = 8;
            bytes_per_elem = 4;
        end

        // AW Channel
        @(posedge clk);
        s_axi_awvalid <= 1;
        s_axi_awaddr  <= addr;
        s_axi_awlen   <= beats - 1; // AXI encoding
        s_axi_awsize  <= 3'b011;    // 8 Bytes (64-bit)
        s_axi_awburst <= 2'b01;     // INCR
        
        wait(s_axi_awready);
        @(posedge clk);
        s_axi_awvalid <= 0;

        // W Channel
        for (int b=0; b < beats; b++) begin
            s_axi_wvalid <= 1;
            s_axi_wstrb  <= 8'hFF;
            s_axi_wlast  <= (b == beats - 1);
            
            // 构造数据包
            // 简单起见，我们在每个 Byte (Int8) 或 Word (Int32) 重复写入 val
            // 实际应用中这里应该更复杂
            if (mode == 0) begin // Int8 (packing 8 bytes into 64-bit)
                // 由于 Unpacker 会把每个字节填充为 32-bit，我们只需要填充低 16 个字节
                // 但这里我们简单地广播 val 到所有字节
                s_axi_wdata <= {(8){8'(val)}}; 
            end else begin // Int32 (packing 2 words into 64-bit)
                s_axi_wdata <= {(2){32'(val)}};
            end

            wait(s_axi_wready);
            @(posedge clk);
        end
        s_axi_wvalid <= 0;
        s_axi_wlast  <= 0;

        // B Channel
        s_axi_bready <= 1;
        wait(s_axi_bvalid);
        @(posedge clk);
        s_axi_bready <= 0;
        
        // $display("[%0t] [AXI-S] Loaded Row @ %h (Mode %0d)", $time, addr, mode);
    endtask

    // ========================================================================
    // 7. AXI Master 模拟 (DDR Model & Monitor)
    // ========================================================================
    // 模拟一个永远 Ready 的从机，并打印写入的数据
    
    initial begin
        m_axi_awready = 1;
        m_axi_wready  = 1;
        m_axi_bvalid  = 0;
        m_axi_bresp   = 0;
        
        forever begin
            @(posedge clk);
            // 简单的 Write Response 逻辑
            if (m_axi_wvalid && m_axi_wready && m_axi_wlast) begin
                @(posedge clk);
                m_axi_bvalid <= 1;
                wait(m_axi_bready);
                @(posedge clk);
                m_axi_bvalid <= 0;
            end
        end
    end

    // 监控写回数据
    always @(posedge clk) begin
        if (m_axi_wvalid && m_axi_wready) begin
            $display("[%0t] [AXI-M Monitor] Write Data: %h", $time, m_axi_wdata);
            // 检查结果
            // 预期结果 0x00000009 (9)
            // 注意: m_axi_wdata 是 64-bit, 包含两个 32-bit 结果
            if (m_axi_wdata[31:0] === 32'h9 || m_axi_wdata[63:32] === 32'h9) begin
                $display("        -> MATCH! Found expected value 9.");
            end
        end
    end

    // ========================================================================
    // 8. 主测试流程
    // ========================================================================
    initial begin
        rst_n = 0;
        #100;
        rst_n = 1;
        $display("[%0t] [Test] System Reset Released.", $time);
        #100;

        // --- Step 1: 通过 AXI Slave 加载数据 (Load SRAM) ---
        $display("\n--- Step 1: Loading SRAM via AXI Slave ---");
        
        // A Matrix (Int8): Addr 0x0000 (Mapped to SRAM Row 0)
        // 写入 8 行，值 = 1
        for(int i=0; i<8; i++) begin
            // 64 Bytes stride for SRAM rows
            axi_write_row(32'h0000 + i*64, 1, 16, 0); 
        end

        // B Matrix (Int8): Addr 0x0400 (Mapped to SRAM Row 16, 16*64=1024)
        // 写入 8 行，值 = 1
        for(int i=0; i<8; i++) begin
            axi_write_row(32'h0400 + i*64, 1, 16, 0);
        end

        // C Matrix (Int32): Addr 0x8000 (Mapped to SRAM Row 512)
        // 写入 16 行 (完整阵列宽)，值 = 1
        // Unpacker 逻辑: addr >= 0x8000 -> Int32 Mode
        for(int i=0; i<16; i++) begin
            axi_write_row(32'h8000 + i*64, 1, 16, 1); 
        end
        $display("[%0t] [Test] Data Loading Complete.", $time);


        // --- Step 2: 通过 APB 配置寄存器 ---
        $display("\n--- Step 2: Configuring Registers via APB ---");
        // Register Map:
        // 0x08: M (16), 0x0C: K (8), 0x10: N (8)
        apb_write(32'h08, 16); // M
        apb_write(32'h0C, 8);  // K
        apb_write(32'h10, 8);  // N
        
        // SRAM Base Addrs (Row Indices)
        // A=0, B=16, C=512, D=256
        apb_write(32'h14, 0);   // Addr A
        apb_write(32'h18, 16);  // Addr B
        apb_write(32'h1C, 512); // Addr C
        apb_write(32'h20, 256); // Addr D (Output)

        // DDR Base Addr
        apb_write(32'h24, 32'hA0000000); // DDR Low
        apb_write(32'h28, 32'h00000000); // DDR High


        // --- Step 3: 启动计算 ---
        $display("\n--- Step 3: Triggering Computation ---");
        // Write CMD_PUSH (0x2C)
        apb_write(32'h2C, 1);

        // --- Step 4: 等待计算完成 ---
        $display("\n--- Step 4: Waiting for Compute Done ---");
        // Polling Status Register (0x04) Bit 1 (Compute Done)
        // Or wait for irq signal
        wait(dut.u_apb.s_compute_done == 1);
        $display("[%0t] [Test] Compute Done Detected!", $time);
        #100; // Safety margin


        // --- Step 5: 启动数据搬运 (Dump to DDR) ---
        $display("\n--- Step 5: Triggering Data Dump ---");
        // Write CTRL (0x00) Bit 1 (START_DUMP)
        apb_write(32'h00, 2);


        // --- Step 6: 观察 AXI Master ---
        $display("\n--- Step 6: Waiting for Data Dump ---");
        wait(dut.u_apb.s_dump_done == 1);
        $display("[%0t] [Test] Dump Done Detected!", $time);

        #500;
        $display("\n--- Test Finished ---");
        $finish;
    end

endmodule
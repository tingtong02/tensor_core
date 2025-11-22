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

    // 寄存器地址映射 (参考 apb_config_slave)
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

    // ========================================================================
    // 2. 信号声明
    // ========================================================================
    logic clk;
    logic rst_n;

    // APB Interface
    logic        psel, penable, pwrite;
    logic [31:0] paddr, pwdata;
    logic [31:0] prdata;
    logic        pready, pslverr;

    // AXI Slave Interface (Host Write Input)
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

    // AXI Master Interface (TPU Write Output)
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
        // Connect all ports...
        .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr), .pwdata(pwdata),
        .prdata(prdata), .pready(pready), .pslverr(pslverr),

        .s_axi_awaddr(s_axi_awaddr), .s_axi_awlen(s_axi_awlen), .s_axi_awsize(s_axi_awsize),
        .s_axi_awburst(s_axi_awburst), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wlast(s_axi_wlast),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),

        .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready)
    );

    // ========================================================================
    // 4. 仿真组件 (BFM & Monitor)
    // ========================================================================
    
    // --- Clock & Reset ---
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // --- APB BFM ---
    task apb_write(input [31:0] addr, input [31:0] data);
        @(negedge clk);
        psel = 1; penable = 0; pwrite = 1; paddr = addr; pwdata = data;
        @(negedge clk);
        penable = 1;
        @(negedge clk);
        psel = 0; penable = 0; pwrite = 0;
    endtask

    task apb_read_poll_bit(input [31:0] addr, input int bit_idx);
        logic [31:0] read_val;
        int timeout;
        timeout = 0;
        
        $display("[APB] Polling Addr %h Bit %0d...", addr, bit_idx);
        forever begin
            @(negedge clk);
            psel = 1; penable = 0; pwrite = 0; paddr = addr;
            @(negedge clk);
            penable = 1;
            @(negedge clk);
            read_val = prdata;
            psel = 0; penable = 0;
            
            if (read_val[bit_idx] == 1) break;
            
            timeout++;
            if (timeout > 10000) begin
                $error("Timeout polling APB Addr %h", addr);
                $finish;
            end
            repeat(10) @(posedge clk);
        end
    endtask

    task apb_write_1_to_clear(input [31:0] addr, input [31:0] data);
        apb_write(addr, data);
        $display("[APB] W1C performed on Addr %h with Data %h", addr, data);
    endtask

    // --- AXI Slave BFM (Host Write) ---
    // 简化: 发送一个 Burst
    task axi_write_matrix(input [31:0] base_addr, input int rows, input int val_start, input int is_int32);
        // 假设 AXI_WIDTH = 64 (8 bytes)
        // Int8: 1 Row (16 cols) = 16 bytes = 2 Beats
        // Int32: 1 Row (16 cols) = 64 bytes = 8 Beats
        
        int beats_per_row;
        int total_beats;
        
        if (is_int32) beats_per_row = 8;
        else          beats_per_row = 2;
        
        total_beats = rows * beats_per_row;

        @(negedge clk);
        // AW Channel
        s_axi_awaddr = base_addr;
        s_axi_awlen  = total_beats - 1; // Single long burst for simplicity
        s_axi_awsize = 3'b011; // 8 bytes
        s_axi_awburst= 2'b01;
        s_axi_awvalid= 1;
        do @(posedge clk); while(!s_axi_awready);
        @(negedge clk);
        s_axi_awvalid= 0;

        // W Channel
        for (int i = 0; i < total_beats; i++) begin
            s_axi_wvalid = 1;
            s_axi_wlast  = (i == total_beats - 1);
            s_axi_wstrb  = '1;
            
            // Construct Dummy Data
            // 简单起见，所有 Byte/Word 都设置为 val_start
            // 这样 A矩阵全是1, B矩阵全是1
            if (is_int32) begin
               s_axi_wdata = {32'(val_start), 32'(val_start)};
            end else begin
               s_axi_wdata = {8{8'(val_start)}};
            end

            do @(posedge clk); while(!s_axi_wready);
            @(negedge clk);
        end
        s_axi_wvalid = 0;
        s_axi_wlast = 0;

        // B Channel
        s_axi_bready = 1;
        do @(posedge clk); while(!s_axi_bvalid);
        @(negedge clk);
        s_axi_bready = 0;
        
        $display("[AXI WRITE] Written Matrix to Addr %h (Rows=%0d, Val=%0d)", base_addr, rows, val_start);
    endtask

    // --- AXI Master Monitor (DDR Memory Model) ---
    // 接收 TPU 写出的数据并校验
    logic [31:0] captured_data [$]; // Queue
    
    initial begin
        m_axi_awready = 1;
        m_axi_wready = 1;
        m_axi_bvalid = 0;
        m_axi_bresp  = 0;
        
        forever begin
            @(posedge clk);
            // Handle Write Data
            if (m_axi_wvalid && m_axi_wready) begin
                // AXI Data is 64-bit (2 * int32)
                // Push into queue
                captured_data.push_back(m_axi_wdata[31:0]);
                captured_data.push_back(m_axi_wdata[63:32]);
            end
            
            // Handle Response
            if (m_axi_wlast && m_axi_wvalid && m_axi_wready) begin
                m_axi_bvalid <= 1;
                do @(posedge clk); while(!m_axi_bready);
                m_axi_bvalid <= 0;
            end
        end
    end

    // ========================================================================
    // 5. 主测试脚本
    // ========================================================================
    initial begin
        // --- Init ---
        rst_n = 0;
        psel = 0; penable = 0; pwrite = 0;
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_bready = 0;
        #50; rst_n = 1; #20;

        $display("=== Simulation Start ===");

        // ------------------------------------------------------------
        // Step 1: 配置寄存器 (M=16, K=16, N=16)
        // ------------------------------------------------------------
        // A Base: 0x0000 (Row 0)
        // B Base: 0x0400 (Row 16) (16 * 64B offset = 1024 = 0x400)
        // C Base: 0x0800 (Row 32) (32 * 64B offset = 2048 = 0x800)
        // D Base: 0x0C00 (Row 48)
        // DDR Base: 0x8000_0000
        
        apb_write(ADDR_M_LEN, 16);
        apb_write(ADDR_K_LEN, 16);
        apb_write(ADDR_N_LEN, 16);
        apb_write(ADDR_ADDR_A, 0);
        apb_write(ADDR_ADDR_B, 16);
        apb_write(ADDR_ADDR_C, 32);
        apb_write(ADDR_ADDR_D, 48);
        apb_write(ADDR_DDR_L, 32'h8000_0000);
        
        $display("[TEST] Configuration Done.");

        // ------------------------------------------------------------
        // Step 2: 写入输入数据 (A, B, C)
        // ------------------------------------------------------------
        // Matrix A: All 1s (Int8) -> SRAM Addr 0 (Offset 0)
        // axi_write_matrix(base_addr, rows, val, is_int32)
        axi_write_matrix(32'h0000_0000, 16, 1, 0); 

        // Matrix B: All 2s (Int8) -> SRAM Addr 16 (Offset 0x400)
        axi_write_matrix(32'h0000_0400, 16, 2, 0);

        // Matrix C: All 5s (Int32) -> SRAM Addr 32 (Offset 0x800)
        // Note: Unpacker treats addr >= 0x8000 as Int32. 
        // We need to be careful with the Unpacker logic in top_tpu.sv
        // In top_tpu.sv: assign cfg_data_type_is_int32 = (s_axi_awaddr[15:0] >= 16'h8000);
        // So we must write C to an address >= 0x8000.
        // Let's use Offset 0x8000 mapping to Row 32?
        // 0x8000 / 64 = 512. This is too high.
        // Let's adjust the test case or assume we write to Row 512 for C.
        // Let's update C Addr Register to 512.
        
        apb_write(ADDR_ADDR_C, 512); // Update C Base to Row 512
        axi_write_matrix(32'h0000_8000, 16, 5, 1); // Write to Offset 0x8000 (Row 512), Int32 Mode

        // ------------------------------------------------------------
        // Step 3: 提交指令并启动计算
        // ------------------------------------------------------------
        apb_write(ADDR_CMD_PUSH, 1); // Commit command
        $display("[TEST] Command Pushed. Computation Started.");

        // ------------------------------------------------------------
        // Step 4: 等待计算完成
        // ------------------------------------------------------------
        // Poll Status Register Bit 1 (Compute Done)
        apb_read_poll_bit(ADDR_STATUS, 1);
        $display("[TEST] Compute Done Interrupt Detected!");
        
        // Clear Interrupt
        apb_write_1_to_clear(ADDR_STATUS, 32'h0000_0002);

        // ------------------------------------------------------------
        // Step 5: 启动数据搬运 (Dump)
        // ------------------------------------------------------------
        apb_write(ADDR_CTRL, 32'h0000_0002); // Set Dump Start Bit
        $display("[TEST] Dump Started.");

        // ------------------------------------------------------------
        // Step 6: 等待搬运完成
        // ------------------------------------------------------------
        // Poll Status Register Bit 2 (Dump Done)
        apb_read_poll_bit(ADDR_STATUS, 2);
        $display("[TEST] Dump Done Interrupt Detected!");

        // ------------------------------------------------------------
        // Step 7: 校验结果
        // ------------------------------------------------------------
        // Calculation: D = (A * B) + C
        // A = all 1s, B = all 2s. Size K=16.
        // A * B (dot product) = sum(1 * 2) for k=0..15 = 16 * 2 = 32.
        // D = 32 + C = 32 + 5 = 37.
        // Expected Result: All elements in D should be 37.
        
        #100;
        if (captured_data.size() != 16 * 16) begin
            $error("Captured Data Size Mismatch! Exp 256, Got %0d", captured_data.size());
        end else begin
            int err_cnt = 0;
            foreach (captured_data[i]) begin
                if (captured_data[i] !== 37) begin
                    $error("Data Mismatch at index %0d: Exp 37, Got %0d", i, captured_data[i]);
                    err_cnt++;
                end
            end
            
            if (err_cnt == 0) $display("=== SUCCESS: All 256 elements are 37! ===");
            else $display("=== FAIL: %0d errors detected ===", err_cnt);
        end

        $finish;
    end

endmodule
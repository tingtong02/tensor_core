`timescale 1ns/1ps

module tb_apb_config_slave;

    // ========================================================================
    // 1. 信号声明
    // ========================================================================
    logic        pclk;
    logic        presetn;
    logic [31:0] paddr;
    logic        psel;
    logic        penable;
    logic        pwrite;
    logic [31:0] pwdata;
    logic [31:0] prdata;
    logic        pready;
    logic        pslverr;

    logic        cmd_valid;
    logic [63:0] cmd_data;
    logic        cmd_ready;
    logic        cu_busy;

    logic        soft_rst;
    logic        compute_done_irq;
    logic        dump_done_irq;

    logic        start_dump;
    logic [63:0] reg_ddr_addr;

    // 寄存器地址映射 (与 DUT 保持一致)
    localparam ADDR_CTRL       = 8'h00;
    localparam ADDR_STATUS     = 8'h04;
    localparam ADDR_M_LEN      = 8'h08;
    localparam ADDR_K_LEN      = 8'h0C;
    localparam ADDR_N_LEN      = 8'h10;
    localparam ADDR_ADDR_A     = 8'h14;
    localparam ADDR_ADDR_B     = 8'h18;
    localparam ADDR_ADDR_C     = 8'h1C;
    localparam ADDR_ADDR_D     = 8'h20;
    localparam ADDR_DDR_L      = 8'h24;
    localparam ADDR_DDR_H      = 8'h28;
    localparam ADDR_CMD_PUSH   = 8'h2C;

    // ========================================================================
    // 2. DUT 实例化
    // ========================================================================
    apb_config_slave #(
        .ADDR_WIDTH(10)
    ) dut (
        .pclk(pclk),
        .presetn(presetn),
        .paddr(paddr),
        .psel(psel),
        .penable(penable),
        .pwrite(pwrite),
        .pwdata(pwdata),
        .prdata(prdata),
        .pready(pready),
        .pslverr(pslverr),

        .cmd_valid(cmd_valid),
        .cmd_data(cmd_data),
        .cmd_ready(cmd_ready),
        .cu_busy(cu_busy),

        .soft_rst(soft_rst),
        .compute_done_irq(compute_done_irq),
        .dump_done_irq(dump_done_irq),

        .start_dump(start_dump),
        .reg_ddr_addr(reg_ddr_addr)
    );

    // ========================================================================
    // 3. APB Bus Functional Model (Tasks)
    // ========================================================================
    
    // 产生时钟
    initial begin
        pclk = 0;
        forever #5 pclk = ~pclk; // 100MHz
    end

    // APB Write Task
    task apb_write(input [31:0] addr, input [31:0] data);
        @(negedge pclk);
        paddr   = addr;
        pwdata  = data;
        pwrite  = 1;
        psel    = 1;
        penable = 0; // Setup Phase
        
        @(negedge pclk);
        penable = 1; // Access Phase
        
        @(negedge pclk); // Wait for ready (DUT is always ready)
        psel    = 0;
        penable = 0;
        pwrite  = 0;
        paddr   = 0;
        pwdata  = 0;
    endtask

    // APB Read Task
    task apb_read(input [31:0] addr, input [31:0] expected_data, input bit check = 1);
        @(negedge pclk);
        paddr   = addr;
        pwrite  = 0;
        psel    = 1;
        penable = 0; // Setup Phase
        
        @(negedge pclk);
        penable = 1; // Access Phase
        
        @(negedge pclk); // Sampling point
        if (check) begin
            if (prdata !== expected_data) begin
                $error("[APB READ FAIL] Addr: %h, Expected: %h, Got: %h", addr, expected_data, prdata);
            end else begin
                $display("[APB READ PASS] Addr: %h, Got: %h", addr, prdata);
            end
        end else begin
             $display("[APB READ INFO] Addr: %h, Got: %h", addr, prdata);
        end
        
        psel    = 0;
        penable = 0;
        paddr   = 0;
    endtask

    // ========================================================================
    // 4. 主测试流程
    // ========================================================================
    initial begin
        // Init
        presetn = 0;
        paddr = 0; psel = 0; penable = 0; pwrite = 0; pwdata = 0;
        cmd_ready = 1; cu_busy = 0;
        compute_done_irq = 0; dump_done_irq = 0;
        
        #100;
        presetn = 1;
        #20;

        $display("=== Test 1: Register R/W Test ===");
        // 配置 M, K, N
        apb_write(ADDR_M_LEN, 32'd32);
        apb_write(ADDR_K_LEN, 32'd64);
        apb_write(ADDR_N_LEN, 32'd128);
        
        // 验证回读
        apb_read(ADDR_M_LEN, 32'd32);
        apb_read(ADDR_K_LEN, 32'd64);
        apb_read(ADDR_N_LEN, 32'd128);

        // 配置 Base Addrs
        apb_write(ADDR_ADDR_A, 32'h100);
        apb_write(ADDR_ADDR_B, 32'h200);
        apb_write(ADDR_ADDR_C, 32'h300);
        apb_write(ADDR_ADDR_D, 32'h400);
        
        // 验证回读
        apb_read(ADDR_ADDR_A, 32'h100);
        apb_read(ADDR_ADDR_D, 32'h400);

        // 配置 DDR Addr (64-bit split)
        apb_write(ADDR_DDR_L, 32'hDEAD_BEEF);
        apb_write(ADDR_DDR_H, 32'h0000_0001);
        
        #10;
        if (reg_ddr_addr !== 64'h0000_0001_DEAD_BEEF) 
            $error("DDR Address Output Mismatch! Got: %h", reg_ddr_addr);
        else
            $display("[DDR ADDR PASS] Output matches combined registers.");

        
        $display("=== Test 2: Command Push (Commit) ===");
        // 此时寄存器里已经有值了，写入 CMD_PUSH 应该触发 cmd_valid
        // 预期的 cmd_data 包格式:
        // [63:54]D, [53:44]C, [43:34]B, [33:24]A, [23:16]N, [15:8]K, [7:0]M
        // D=400(190h), C=300(12Ch), B=200(C8h), A=100(64h)
        // N=128(80h), K=64(40h), M=32(20h)
        // 10-bit addr 190h -> 01_1001_0000
        // Binary Check might be tedious, let's check fields via struct logic simulation
        
        fork
            begin
                apb_write(ADDR_CMD_PUSH, 32'h1); // Value doesn't matter
            end
            begin
                // 监控输出
                wait(cmd_valid == 1);
                $display("[PUSH PASS] cmd_valid pulse detected.");
                // 检查数据内容
                if (cmd_data[7:0] == 32 && cmd_data[23:16] == 128 && cmd_data[33:24] == 'h100)
                    $display("[PACK PASS] cmd_data content looks correct.");
                else
                    $error("[PACK FAIL] cmd_data mismatch. Got %h", cmd_data);
            end
        join


        $display("=== Test 3: Dump Trigger ===");
        // Write CTRL reg bit 1
        fork
            begin
                apb_write(ADDR_CTRL, 32'h2); // Set Bit 1
            end
            begin
                wait(start_dump == 1);
                $display("[DUMP PASS] start_dump pulse detected.");
            end
        join


        $display("=== Test 4: Status & Interrupt W1C ===");
        // 1. 模拟硬件产生中断
        @(negedge pclk);
        compute_done_irq = 1; // Compute done
        @(negedge pclk);
        compute_done_irq = 0;
        
        // 2. 读状态寄存器 (Expect Bit 1 = 1)
        apb_read(ADDR_STATUS, 32'h0000_0002, 0); // Busy=0, Compute=1, Dump=0
        if (prdata[1] !== 1) $error("Status Bit 1 (Compute Done) not set!");

        // 3. 模拟 CU Busy
        cu_busy = 1;
        #1;
        apb_read(ADDR_STATUS, 32'h0000_0003, 0); // Busy=1, Compute=1
        if (prdata[0] !== 1) $error("Status Bit 0 (Busy) not set!");
        cu_busy = 0;

        // 4. 清除中断 (W1C) - Write 1 to Bit 1
        apb_write(ADDR_STATUS, 32'h0000_0002); 
        
        // 5. 再次读状态 (Expect Bit 1 = 0)
        apb_read(ADDR_STATUS, 32'h0000_0000, 1); // All clear
        if (prdata[1] !== 0) $error("Status Bit 1 did not clear after W1C!");
        else $display("[W1C PASS] Status bit cleared correctly.");


        $display("=== Test 5: Soft Reset ===");
        apb_write(ADDR_CTRL, 32'h4); // Bit 2
        #1;
        if (soft_rst !== 1) $error("Soft Reset output not high!");
        else $display("[RST PASS] Soft Reset verified.");
        
        apb_write(ADDR_CTRL, 32'h0); // Release
        #1;
        if (soft_rst !== 0) $error("Soft Reset did not release!");

        $display("=== All Tests Finished ===");
        $finish;
    end

endmodule
`timescale 1ns/1ps

module tb_unified_buffer;

    // ==========================================
    // 1. 参数配置
    // ==========================================
    // 保持与 DUT 默认参数一致，方便对接
    parameter int DATA_WIDTH           = 32;
    parameter int SYSTOLIC_ARRAY_WIDTH = 16; // 默认 16 宽
    parameter int ADDR_WIDTH           = 10; // 1024 深度

    // ==========================================
    // 2. 信号声明
    // ==========================================
    logic clk;
    
    // 注意：你的 UB 设计中没有 Reset 端口，这对于大容量 SRAM 是正常的
    
    // --- 写端口 (Write Port) ---
    logic [ADDR_WIDTH-1:0] wr_addr;
    logic                  wr_en;
    logic [DATA_WIDTH-1:0] wr_data [SYSTOLIC_ARRAY_WIDTH];

    // --- 读端口 A, B, C (Read Ports) ---
    logic [ADDR_WIDTH-1:0]  rd_addr_a, rd_addr_b, rd_addr_c;
    logic                   rd_en_a, rd_en_b, rd_en_c;
    logic [DATA_WIDTH-1:0]  rd_data_a [SYSTOLIC_ARRAY_WIDTH];
    logic [DATA_WIDTH-1:0]  rd_data_b [SYSTOLIC_ARRAY_WIDTH];
    logic [DATA_WIDTH-1:0]  rd_data_c [SYSTOLIC_ARRAY_WIDTH];

    // ==========================================
    // 3. 实例化 DUT
    // ==========================================
    unified_buffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .SYSTOLIC_ARRAY_WIDTH(SYSTOLIC_ARRAY_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_dut (
        .clk       (clk),
        
        // Write Port
        .wr_addr   (wr_addr),
        .wr_en     (wr_en),
        .wr_data   (wr_data),

        // Read Port A
        .rd_addr_a (rd_addr_a),
        .rd_en_a   (rd_en_a),
        .rd_data_a (rd_data_a),

        // Read Port B
        .rd_addr_b (rd_addr_b),
        .rd_en_b   (rd_en_b),
        .rd_data_b (rd_data_b),

        // Read Port C
        .rd_addr_c (rd_addr_c),
        .rd_en_c   (rd_en_c),
        .rd_data_c (rd_data_c)
    );

    // ==========================================
    // 4. 基础设施: 时钟生成
    // ==========================================
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // ==========================================
    // 5. 辅助任务 (Helper Tasks)
    // ==========================================
    // 导师提示：手动给 data[0]..data[15] 赋值太痛苦了。
    // 我们写一个 task 来自动生成数据模式。
    
    // Task: 向指定地址写入一行数据 (Pattern: Base + Lane_ID)
    task automatic write_row(
        input logic [ADDR_WIDTH-1:0] addr,
        input int                    base_val
    );
        @(posedge clk);
        wr_en   <= 1'b1;
        wr_addr <= addr;
        // 生成数据: Lane 0 = Base+0, Lane 1 = Base+1 ...
        foreach(wr_data[i]) begin
            wr_data[i] <= base_val + i;
        end
        
        // 下一拍释放写使能
        @(posedge clk);
        wr_en   <= 1'b0;
        wr_addr <= '0;
        foreach(wr_data[i]) wr_data[i] <= '0; 
    endtask

    // Task: 检查读出的数据是否符合预期
    task automatic check_row(
        input string                 port_name, // "Port A", "Port B"...
        input logic [DATA_WIDTH-1:0] actual_data [SYSTOLIC_ARRAY_WIDTH],
        input int                    expected_base_val
    );
        int error_count = 0;
        $display("[Check] Verifying %s...", port_name);
        
        foreach(actual_data[i]) begin
            if (actual_data[i] !== expected_base_val + i) begin
                $error("    Lane %0d Error: Expected %0d, Got %0d", 
                        i, expected_base_val + i, actual_data[i]);
                error_count++;
            end
        end
        
        if (error_count == 0) 
            $display("    Pass! All lanes match base %0d.", expected_base_val);
    endtask

    // ==========================================
    // 6. 主测试流程
    // ==========================================
    initial begin
        // --- A. 初始化 ---
        $display("=== Unified Buffer Simulation Start ===");
        wr_en = 0; rd_en_a = 0; rd_en_b = 0; rd_en_c = 0;
        wr_addr = 0; rd_addr_a = 0; rd_addr_b = 0; rd_addr_c = 0;
        // 初始化数组
        foreach(wr_data[i]) wr_data[i] = 0;
        
        // 等待电路稳定 (RAM 通常不需要复位，但需要等待上电)
        #50;

        // ==========================================
        // TC1: 基础写读测试 (Write & Read Check)
        // 目标: 写入 Addr 10, 然后通过 Port A 读出来
        // ==========================================
        $display("\n--- TC1: Basic Write & Read (Port A) ---");
        
        // 1. 写入地址 10, 基准值 1000 (Lane0=1000, Lane1=1001...)
        write_row(.addr(10), .base_val(1000));

        // 2. 发起读请求 (Port A 读 Addr 10)
        @(posedge clk);
        rd_en_a   <= 1'b1;
        rd_addr_a <= 10;
        
        // 3. 等待读取延迟 (RAM Latency = 1 cycle) 
        @(posedge clk);
        rd_en_a   <= 1'b0; // 请求结束
        
        // 此时 (T+1)，数据应该已经出现在 rd_data_a 上了
        // 我们再等一个小的延时(#1)确保数据稳定再检查，或者直接在当前沿检查
        #1; 
        check_row("Port A (Addr 10)", rd_data_a, 1000);


        // ==========================================
        // TC2: 多端口并发读取 (Multi-Port Read)
        // 目标: 写入 Addr 55, 同时从 A, B, C 三个口读它
        // ==========================================
        $display("\n--- TC2: Simultaneous 3-Port Read ---");
        
        // 1. 写入地址 55, 基准值 5500
        write_row(.addr(55), .base_val(5500));

        // 2. 同时发起读请求
        @(posedge clk);
        rd_en_a <= 1'b1; rd_addr_a <= 55;
        rd_en_b <= 1'b1; rd_addr_b <= 55;
        rd_en_c <= 1'b1; rd_addr_c <= 55;

        // 3. 等待延迟
        @(posedge clk);
        rd_en_a <= 0; rd_en_b <= 0; rd_en_c <= 0;

        // 4. 检查结果
        #1;
        check_row("Port A (Addr 55)", rd_data_a, 5500);
        check_row("Port B (Addr 55)", rd_data_b, 5500);
        check_row("Port C (Addr 55)", rd_data_c, 5500);


        // ==========================================
        // TC3: 地址独立性测试 (Address Independence)
        // 目标: 确保写 Addr 100 不会覆盖 Addr 10
        // ==========================================
        $display("\n--- TC3: Address Independence ---");
        
        // 写入地址 100 (Base 9999)
        write_row(.addr(100), .base_val(9999));
        
        // 读回之前写的地址 10 (Base 1000 from TC1)
        @(posedge clk);
        rd_en_a <= 1'b1; rd_addr_a <= 10; // 读老地址
        
        @(posedge clk);
        rd_en_a <= 0;
        
        #1;
        // 如果这里读出了 9999，说明地址译码错了或者覆盖了
        check_row("Port A (Addr 10 - Old Data)", rd_data_a, 1000);


        $display("\n=== Simulation Finished ===");
        $finish;
    end

endmodule
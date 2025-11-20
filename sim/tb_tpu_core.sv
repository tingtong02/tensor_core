`timescale 1ns/1ps

module tb_tpu_core;

    // ========================================================================
    // 1. 参数定义
    // ========================================================================
    parameter int SYSTOLIC_ARRAY_WIDTH = 16;
    parameter int DATA_WIDTH_IN        = 8;
    parameter int DATA_WIDTH_ACCUM     = 32;
    parameter int ADDR_WIDTH           = 10;
    
    localparam W = SYSTOLIC_ARRAY_WIDTH;

    // ========================================================================
    // 2. 信号声明
    // ========================================================================
    logic clk;
    logic rst;

    // Host Interface (Write)
    logic [ADDR_WIDTH-1:0]       host_wr_addr_in;
    logic                        host_wr_en_in;
    logic [DATA_WIDTH_ACCUM-1:0] host_wr_data_in [SYSTOLIC_ARRAY_WIDTH];

    // AXI Master Interface (Read)
    logic [ADDR_WIDTH-1:0]       axim_rd_addr_in;
    logic                        axim_rd_en_in;
    logic [DATA_WIDTH_ACCUM-1:0] axim_rd_data_out [SYSTOLIC_ARRAY_WIDTH];

    // Control Signals (Simulating Control Unit)
    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_a;
    logic                  ctrl_rd_en_a;
    logic                  ctrl_a_valid;
    logic                  ctrl_a_switch;

    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_b;
    logic                  ctrl_rd_en_b;
    logic                  ctrl_b_accept_w;
    logic [$clog2(W)-1:0]  ctrl_b_weight_index;

    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_c;
    logic                  ctrl_rd_en_c;
    logic                  ctrl_c_valid;
    logic [2:0]            ctrl_vpu_mode;

    logic [ADDR_WIDTH-1:0] ctrl_wr_addr_d;
    
    logic [W-1:0] ctrl_row_mask;
    logic [W-1:0] ctrl_col_mask;

    // Output Status
    logic core_writeback_valid;

    // ========================================================================
    // 3. DUT 实例化 (Device Under Test)
    // ========================================================================
    tpu_core #(
        .SYSTOLIC_ARRAY_WIDTH(SYSTOLIC_ARRAY_WIDTH),
        .DATA_WIDTH_IN(DATA_WIDTH_IN),
        .DATA_WIDTH_ACCUM(DATA_WIDTH_ACCUM),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
        .clk(clk),
        .rst(rst),
        
        .host_wr_addr_in(host_wr_addr_in),
        .host_wr_en_in(host_wr_en_in),
        .host_wr_data_in(host_wr_data_in),

        .axim_rd_addr_in(axim_rd_addr_in),
        .axim_rd_en_in(axim_rd_en_in),
        .axim_rd_data_out(axim_rd_data_out),

        .ctrl_rd_addr_a(ctrl_rd_addr_a), .ctrl_rd_en_a(ctrl_rd_en_a),
        .ctrl_a_valid(ctrl_a_valid),     .ctrl_a_switch(ctrl_a_switch),

        .ctrl_rd_addr_b(ctrl_rd_addr_b), .ctrl_rd_en_b(ctrl_rd_en_b),
        .ctrl_b_accept_w(ctrl_b_accept_w), .ctrl_b_weight_index(ctrl_b_weight_index),

        .ctrl_rd_addr_c(ctrl_rd_addr_c), .ctrl_rd_en_c(ctrl_rd_en_c),
        .ctrl_c_valid(ctrl_c_valid),     .ctrl_vpu_mode(ctrl_vpu_mode),

        .ctrl_wr_addr_d(ctrl_wr_addr_d),
        .ctrl_row_mask(ctrl_row_mask),
        .ctrl_col_mask(ctrl_col_mask),

        .core_writeback_valid(core_writeback_valid)
    );

    // ========================================================================
    // 4. 时钟生成
    // ========================================================================
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100MHz Clock
    end

    // ========================================================================
    // 5. 辅助任务 (Helper Tasks)
    // ========================================================================
    
    // 任务 1: 初始化所有信号 (修复 XXX 态)
    task init_signals();
        rst = 1;
        
        // --- 初始化 Host Write 接口 ---
        host_wr_en_in = 0;
        host_wr_addr_in = 0;
        for (int i = 0; i < SYSTOLIC_ARRAY_WIDTH; i++) begin
            host_wr_data_in[i] = 0; // 显式清零数组
        end

        // --- 初始化 AXI Read 接口 ---
        axim_rd_en_in = 0;
        axim_rd_addr_in = 0;
        
        // --- 初始化 Control Unit 接口 ---
        ctrl_rd_en_a = 0; ctrl_a_valid = 0; ctrl_a_switch = 0; ctrl_rd_addr_a = 0;
        ctrl_rd_en_b = 0; ctrl_b_accept_w = 0; ctrl_rd_addr_b = 0; ctrl_b_weight_index = 0;
        ctrl_rd_en_c = 0; ctrl_c_valid = 0; ctrl_rd_addr_c = 0;
        
        ctrl_vpu_mode = 3'b001; // Default: Enable Bias Add
        ctrl_row_mask = 16'h0003; // Default: Enable Row 0, 1
        ctrl_col_mask = 16'h0003; // Default: Enable Col 0, 1
        ctrl_wr_addr_d = 0;

        #100;
        rst = 0;
        #20;
    endtask

    // 任务 2: 写入 Input Buffer (优化: 下降沿驱动)
    // 模拟 AXI 解包器写入一行数据
    task write_ib_row(input int addr, input int val0, input int val1);
        // 1. 等待时钟下降沿 (确保 Setup Time 充足，且波形清晰)
        @(negedge clk);
        
        // 2. 驱动数据
        host_wr_addr_in = addr;
        host_wr_en_in = 1;
        for(int i=0; i<W; i++) begin
            if (i==0) host_wr_data_in[i] = val0;
            else if (i==1) host_wr_data_in[i] = val1;
            else host_wr_data_in[i] = 0; // Padding
        end
        
        // 3. 保持一个完整周期
        @(negedge clk);
        
        // 4. 撤销使能
        host_wr_en_in = 0;
    endtask

    // ========================================================================
    // 6. 主测试流程 (Main Sequence)
    // ========================================================================
    initial begin
        // --- Step 0: Init ---
        init_signals();
        $display("=== Simulation Start ===");

        // --- Step 1: Load Input Buffer (Host Write) ---
        $display("[T=0] Loading Input Buffer...");
        
        // Load Matrix A (Addr 0~1) -> A[0]=[1,2], A[1]=[3,4]
        write_ib_row(0, 1, 2); 
        write_ib_row(1, 3, 4); 

        // Load Matrix B (Addr 10~11) -> B[0]=[5,6], B[1]=[7,8]
        write_ib_row(10, 5, 6);
        write_ib_row(11, 7, 8);

        // Load Matrix C (Addr 20~21) -> C[0]=[1,1], C[1]=[1,1]
        write_ib_row(20, 1, 1);
        write_ib_row(21, 1, 1);

        #50;

        // --- Step 2: Run Calculation (Simulate Control Unit) ---
        $display("[T=Now] Starting Calculation Sequence...");

        // -------------------------------------------------------
        // 2a. B-Flow (Load Weights)
        // -------------------------------------------------------
        // 模拟: Control Unit 倒序请求 B 矩阵
        
        // Time Step 0: Request B[1] (Row 11)
        @(negedge clk); // 使用 negedge 驱动控制信号
        ctrl_rd_en_b = 1; ctrl_rd_addr_b = 11;
        
        // Time Step 1: Data B[1] Valid -> Accept Index 1, Request B[0] (Row 10)
        @(negedge clk);
        ctrl_b_accept_w = 1; ctrl_b_weight_index = 1; 
        ctrl_rd_en_b = 1; ctrl_rd_addr_b = 10;
        
        // Time Step 2: Data B[0] Valid -> Accept Index 0, Stop Request
        @(negedge clk);
        ctrl_b_accept_w = 1; ctrl_b_weight_index = 0;
        ctrl_rd_en_b = 0;
        
        // Time Step 3: Cleanup B signals
        @(negedge clk);
        ctrl_b_accept_w = 0;
        
        // 等待直到 T=W (即第16个周期) 进行 Switch
        // (这里简化等待时间，只要足够 B 加载完成)
        repeat(13) @(negedge clk); 

        // -------------------------------------------------------
        // 2b. Switch & A-Flow & C-Flow
        // -------------------------------------------------------
        // T=W: Switch 信号 (Update Weights)
        ctrl_a_switch = 1;
        @(negedge clk);
        ctrl_a_switch = 0;

        // T=W+1: Start Streaming A (Row 0 -> Row 1)
        
        // Request A Row 0
        ctrl_rd_en_a = 1; ctrl_rd_addr_a = 0;
        @(negedge clk);
        
        // Request A Row 1 + A Valid (Row 0 is valid now)
        ctrl_rd_en_a = 1; ctrl_rd_addr_a = 1;
        ctrl_a_valid = 1; 
        @(negedge clk);

        // Stop Request + A Valid (Row 1 is valid now)
        ctrl_rd_en_a = 0;
        ctrl_a_valid = 1; 
        @(negedge clk);

        ctrl_a_valid = 0;

        // Wait for C timing (Bias should arrive later)
        repeat(13) @(negedge clk);

        // Stream C Row 0
        ctrl_rd_en_c = 1; ctrl_rd_addr_c = 20;
        @(negedge clk);

        // Stream C Row 1 + C Valid
        ctrl_rd_en_c = 1; ctrl_rd_addr_c = 21;
        ctrl_c_valid = 1;
        @(negedge clk);

        // Stop C Request + C Valid
        ctrl_rd_en_c = 0;
        ctrl_c_valid = 1;
        @(negedge clk);
        ctrl_c_valid = 0;

        // --- Step 3: Wait for Output ---
        
        // 1. 等待 Valid 信号拉高 (Row 0 出现)
        wait(core_writeback_valid == 1);
        $display("[Result] Writeback Row 0 detected at Addr %0d", ctrl_wr_addr_d);
        
        // [关键修复]: 必须等待一个上升沿，确保 SRAM 在地址 0 完成写入
        @(posedge clk); 
        
        // 2. 现在的时刻，Row 0 已经写入 mem[0]，可以安全切换地址了
        @(negedge clk);
        ctrl_wr_addr_d = 1; 

        // 3. 检查 Row 1
        if (core_writeback_valid) begin
             // 如果 Valid 仍然为高 (Back-to-Back 连续输出)
             $display("[Result] Writeback Row 1 detected at Addr %0d", ctrl_wr_addr_d);
             // 等待 Row 1 写入完成
             @(posedge clk);
        end else begin
             // 如果 Valid 中间有气泡 (不太可能，但为了健壮性)
             wait(core_writeback_valid == 1);
             $display("[Result] Writeback Row 1 detected at Addr %0d", ctrl_wr_addr_d);
             @(posedge clk);
        end
        
        // 任务结束，复位地址
        @(negedge clk);
        ctrl_wr_addr_d = 0;

                // --- Step 4: Verify Read (AXI Master) ---
                $display("Verifying Results...");
                
                // -------------------------------------------------------
                // 验证 D[0] (非流水线读：发地址 -> 等数据 -> 检查)
                // -------------------------------------------------------
                @(negedge clk);
                axim_rd_en_in = 1; 
                axim_rd_addr_in = 0; // 请求 D[0]
                
                @(negedge clk);
                axim_rd_en_in = 0;   // 停止请求
                // SRAM 在上一个上升沿采样了地址 0
                // 它是 1 周期延迟，所以数据会在下一个上升沿出现
                
                @(posedge clk);      // 等待数据输出
                #1;                  //稍微延时一点点，确保信号稳定
                
                if (axim_rd_data_out[0] == 20 && axim_rd_data_out[1] == 23)
                    $display("PASS: D[0] = {%d, %d}", axim_rd_data_out[0], axim_rd_data_out[1]);
                else
                    $error("FAIL: D[0] Expected {20, 23}, Got {%d, %d}", axim_rd_data_out[0], axim_rd_data_out[1]);
        
                // -------------------------------------------------------
                // 验证 D[1]
                // -------------------------------------------------------
                @(negedge clk);
                axim_rd_en_in = 1; 
                axim_rd_addr_in = 1; // 请求 D[1]
                
                @(negedge clk);
                axim_rd_en_in = 0;   // 停止请求
                
                @(posedge clk);      // 等待数据输出
                #1;
                
                if (axim_rd_data_out[0] == 44 && axim_rd_data_out[1] == 51)
                    $display("PASS: D[1] = {%d, %d}", axim_rd_data_out[0], axim_rd_data_out[1]);
                else
                    $error("FAIL: D[1] Expected {44, 51}, Got {%d, %d}", axim_rd_data_out[0], axim_rd_data_out[1]);
        
                $display("=== Simulation End ===");
                $finish;
    end

    // Dump waves
    initial begin
        $dumpfile("tpu_core.vcd");
        $dumpvars(0, tb_tpu_core);
    end

endmodule
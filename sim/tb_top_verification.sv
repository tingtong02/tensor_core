`timescale 1ns/1ps
`default_nettype none

/**
 * Testbench for: top_verification
 *
 * 功能: 
 * 1. 实例化 DUT (top_verification)
 * 2. 生成时钟 (clk) 和复位 (rst) 信号
 * 3. 实现了基于 "黄金模型" 的自校验测试
 * 4. 模拟 CPU (CSR), Host DMA (Buffer Load) 和 AXI Master (Result Readback)
 */
module tb_top_verification;

    // --- 1. 参数定义 (匹配 DUT) ---
    //
    localparam int W                  = 16;
    localparam int DATA_WIDTH_IN      = 8;
    localparam int DATA_WIDTH_ACCUM   = 32;
    localparam int ADDR_WIDTH         = 10;
    localparam int CSR_ADDR_WIDTH     = 8;
    
    // --- 2. 测试用例参数 ---
    //
    localparam int TEST_M = 4;
    localparam int TEST_K = 4;
    localparam int TEST_N = 4;
    // 关键! 匹配 "单次运行" 时间线
    localparam int LATENCY_C_VAL = W;       // (t=2W+1)
    localparam int LATENCY_D_VAL = W + 1;   // (t=2W+2)
    
    // Testbench 控制
    localparam real CLK_PERIOD_NS        = 10.0; // 100MHz 时钟

    // --- 3. Testbench 信号声明 ---
    
    // 时钟与复位
    logic tb_clk;
    logic tb_rst;

    // CSR 接口 (Inputs to DUT)
    logic [CSR_ADDR_WIDTH-1:0]          tb_csr_addr;
    logic                               tb_csr_wr_en;
    logic [31:0]                        tb_csr_wr_data;
    logic                               tb_csr_rd_en;
    
    // CSR 接口 (Outputs from DUT)
    logic [31:0]                        tb_csr_rd_data;

    // Host 接口 (Inputs to DUT)
    logic [ADDR_WIDTH-1:0]              tb_host_wr_addr_in;
    logic                               tb_host_wr_en_in;
    logic [DATA_WIDTH_ACCUM-1:0]        tb_host_wr_data_in [W];

    // AXI Master 接口 (Outputs from DUT)
    logic                               tb_axi_master_start_pulse;
    logic [31:0]                        tb_axi_master_dest_addr;
    logic [ADDR_WIDTH-1:0]              tb_axi_master_src_addr;
    logic [15:0]                        tb_axi_master_length;
    
    // AXI Master 接口 (Inputs to DUT)
    logic                               tb_axi_master_done_irq;
    logic [ADDR_WIDTH-1:0]              tb_axim_rd_addr_in;
    logic                               tb_axim_rd_en_in;
    
    // AXI Master 接口 (Outputs from DUT)
    logic [DATA_WIDTH_ACCUM-1:0]        tb_axim_rd_data_out [W];

    // --- 4. Testbench 存储和 "黄金" 模型 ---
    //
    // 黄金输入数据 (int8)
    logic signed [DATA_WIDTH_IN-1:0]    A_golden [TEST_M][TEST_K];
    logic signed [DATA_WIDTH_IN-1:0]    B_golden [TEST_K][TEST_N];
    logic signed [DATA_WIDTH_ACCUM-1:0] C_golden [TEST_M][TEST_N];
    // 黄金输出结果 (int32)
    logic signed [DATA_WIDTH_ACCUM-1:0] D_golden [TEST_M][TEST_N];
    // 模拟 DDR (用于 AXI Master 写回)
    logic [DATA_WIDTH_ACCUM-1:0]        ddr_results [TEST_M][TEST_N];

    // ==========================================================
    // 已修复: localparam 必须在模块级别声明
    // ==========================================================
    // A, B, C 在 buffer 中的基地址
    localparam BASE_A = 10'h000;
    localparam BASE_B = 10'h040;
    localparam BASE_C = 10'h080;
    localparam BASE_D = 10'h100; // Output Buffer 基地址


    // --- 5. DUT 实例化 ---
    //
    top_verification #(
        .SYSTOLIC_ARRAY_WIDTH(W),
        .DATA_WIDTH_IN       (DATA_WIDTH_IN),
        .DATA_WIDTH_ACCUM    (DATA_WIDTH_ACCUM),
        .ADDR_WIDTH          (ADDR_WIDTH),
        .CSR_ADDR_WIDTH      (CSR_ADDR_WIDTH)
    ) uut (
        // 时钟与复位
        .clk(tb_clk),
        .rst(tb_rst),

        // 1. CSR 接口
        .csr_addr      (tb_csr_addr),
        .csr_wr_en     (tb_csr_wr_en),
        .csr_wr_data   (tb_csr_wr_data),
        .csr_rd_en     (tb_csr_rd_en),
        .csr_rd_data   (tb_csr_rd_data),

        // 2. Host 接口
        .host_wr_addr_in(tb_host_wr_addr_in),
        .host_wr_en_in  (tb_host_wr_en_in),
        .host_wr_data_in(tb_host_wr_data_in),

        // 3. AXI Master 接口
        .axi_master_start_pulse(tb_axi_master_start_pulse),
        .axi_master_dest_addr  (tb_axi_master_dest_addr),
        .axi_master_src_addr   (tb_axi_master_src_addr),
        .axi_master_length     (tb_axi_master_length),
        .axi_master_done_irq   (tb_axi_master_done_irq),
        .axim_rd_addr_in (tb_axim_rd_addr_in),
        .axim_rd_en_in   (tb_axim_rd_en_in),
        .axim_rd_data_out(tb_axim_rd_data_out)
    );

    // --- 6. 时钟生成 ---
    //
    always begin
        #((CLK_PERIOD_NS / 2.0)) tb_clk = ~tb_clk;
    end

    // --- 7. 复位与信号初始化 ---
    //
    initial begin
        // 初始化时钟
        tb_clk = 1'b0;
        
        // 置于复位状态
        tb_rst = 1'b1;

        // 初始化所有 DUT 输入为已知的空闲状态
        tb_csr_addr            = '0;
        tb_csr_wr_en           = 1'b0;
        tb_csr_wr_data         = '0;
        tb_csr_rd_en           = 1'b0;
        tb_host_wr_addr_in     = '0;
        tb_host_wr_en_in       = 1'b0;
        tb_axi_master_done_irq = 1'b0;
        tb_axim_rd_addr_in     = '0;
        tb_axim_rd_en_in       = 1'b0;

        // 初始化数组输入
        foreach (tb_host_wr_data_in[i]) begin
            tb_host_wr_data_in[i] = '0;
        end
        
        // 保持复位 2 个时钟周期
        #(CLK_PERIOD_NS * 2);
        
        // 释放复位
        tb_rst = 1'b0;
    end

    // --- 8. Testbench 任务 (Tasks) ---

    // 任务: CSR 写
    task csr_write(input [CSR_ADDR_WIDTH-1:0] addr, input [31:0] data);
        @(posedge tb_clk);
        tb_csr_addr    <= addr;
        tb_csr_wr_data <= data;
        tb_csr_wr_en   <= 1;
        @(posedge tb_clk);
        tb_csr_wr_en   <= 0;
        tb_csr_addr    <= '0;
        tb_csr_wr_data <= '0;
    endtask

    // 任务: CSR 读
    task csr_read(input [CSR_ADDR_WIDTH-1:0] addr, output [31:0] data);
        @(posedge tb_clk);
        tb_csr_addr  <= addr;
        tb_csr_rd_en <= 1;
        @(posedge tb_clk);
        @(posedge tb_clk); // 1 拍地址, 1 拍数据
        data         <= tb_csr_rd_data;
        tb_csr_rd_en <= 0;
        tb_csr_addr  <= '0;
    endtask

    // 任务: Host 写 (加载 Input Buffer)
    task host_write(input [ADDR_WIDTH-1:0] addr, input [DATA_WIDTH_ACCUM-1:0] data [W]);
        @(posedge tb_clk);
        tb_host_wr_addr_in <= addr;
        tb_host_wr_en_in   <= 1;
        tb_host_wr_data_in <= data;
        @(posedge tb_clk);
        tb_host_wr_en_in   <= 0;
    endtask
    
    // ========================================================================
    // 9. 测试序列 (Test Sequence)
    // (逻辑移植自 tb_tpu.sv)
    // ========================================================================
    initial begin
        int errors = 0;
        logic [31:0] status_reg;
        
        // ==========================================================
        // 已修复: logic 声明必须在 initial 块的顶部
        // ==========================================================
        logic [DATA_WIDTH_ACCUM-1:0] row_data [W];
        
        $display("[%0t] TB: --- Test Start ---", $time);

        // --- 1. 初始化黄金数据 (简单单位矩阵) ---
        $display("[%0t] TB: Initializing Golden Data...", $time);
        for (int i = 0; i < TEST_M; i++) begin
            for (int j = 0; j < TEST_K; j++) begin
                A_golden[i][j] = (i == j) ? 1 : 0; // A = Identity
            end
        end
        for (int i = 0; i < TEST_K; i++) begin
            for (int j = 0; j < TEST_N; j++) begin
                B_golden[i][j] = (i == j) ? 2 : 0; // B = 2*Identity
            end
        end
        for (int i = 0; i < TEST_M; i++) begin
            for (int j = 0; j < TEST_N; j++) begin
                C_golden[i][j] = 3; // C = 3
            end
        end

        // --- 2. 计算黄金结果 (D = A*B + C) ---
        // D = (I * 2I) + 3 = 2I + 3
        // D[i][j] = 5 if i==j, else 3
        for (int i = 0; i < TEST_M; i++) begin
            for (int j = 0; j < TEST_N; j++) begin
                D_golden[i][j] = C_golden[i][j]; // Start with C
                for (int l = 0; l < TEST_K; l++) begin
                    D_golden[i][j] += $signed(A_golden[i][l]) * $signed(B_golden[l][j]);
                end
            end
        end
        
        // --- 等待复位结束 ---
        @(posedge tb_clk);
        while (tb_rst) @(posedge tb_clk);
        $display("[%0t] TB: Reset finished.", $time);

        // --- 3. 加载数据到 Input Buffer (模拟 DMA) ---
        // (localparam 已被移到模块顶部)

        // (logic row_data 已被移到此块顶部)
        
        // 加载 A (M=4, K=4)
        $display("[%0t] TB: Loading Matrix A...", $time);
        for (int i = 0; i < TEST_M; i++) begin
            for (int j = 0; j < W; j++) begin
                row_data[j] = (j < TEST_K) ? A_golden[i][j] : '0;
            end
            host_write(BASE_A + i, row_data);
        end

        // 加载 B (K=4, N=4)
        $display("[%0t] TB: Loading Matrix B...", $time);
        for (int i = 0; i < TEST_K; i++) begin
            for (int j = 0; j < W; j++) begin
                row_data[j] = (j < TEST_N) ? B_golden[i][j] : '0;
            end
            host_write(BASE_B + i, row_data);
        end

        // 加载 C (M=4, N=4)
        $display("[%0t] TB: Loading Matrix C...", $time);
        for (int i = 0; i < TEST_M; i++) begin
            for (int j = 0; j < W; j++) begin
                row_data[j] = (j < TEST_N) ? C_golden[i][j] : '0;
            end
            host_write(BASE_C + i, row_data);
        end
        
        // --- 4. 配置 Control Unit (模拟 CPU) ---
        $display("[%0t] TB: Configuring Control Unit...", $time);
        csr_write(8'h10, TEST_M);         // ADDR_DIM_M
        csr_write(8'h14, TEST_K);         // ADDR_DIM_K
        csr_write(8'h18, TEST_N);         // ADDR_DIM_N
        csr_write(8'h20, BASE_A);         // ADDR_A
        csr_write(8'h24, BASE_B);         // ADDR_B
        csr_write(8'h28, BASE_C);         // ADDR_C
        csr_write(8'h2C, BASE_D);         // ADDR_D
        csr_write(8'h30, 32'h80000000);   // ADDR_DDR
        csr_write(8'h38, LATENCY_C_VAL);  // ADDR_LATENCY_C
        csr_write(8'h3C, LATENCY_D_VAL);  // ADDR_LATENCY_D

        // --- 5. 启动 TPU ---
        $display("[%0t] TB: *** STARTING TPU *** (t_start=0)", $time);
        csr_write(8'h00, 1); // ADDR_CONTROL (Start)
        
        // --- 6. 模拟 AXI Master (读回 D) ---
        // 这个 'fork/join_none' 块模拟了 AXI Master DMA，
        // 它与 DUT 并行运行。
        fork
            begin
                $display("[%0t] TB: AXI Master DMA standing by...", $time);
                // 等待 Control Unit 发出启动信号
                @(posedge tb_axi_master_start_pulse);
                $display("[%0t] TB: AXI Master DMA Start Pulse received!", $time);
                
                // 验证地址和长度 (来自 CU)
                if (tb_axi_master_src_addr !== BASE_D) begin
                    $display("[%0t] TB: ERROR! AXI Master src_addr mismatch. Expected %h, Got %h", $time, BASE_D, tb_axi_master_src_addr);
                    errors++;
                end
                
                // 从 Output Buffer 读回 M*N 行数据
                for (int i = 0; i < TEST_M; i++) begin
                    @(posedge tb_clk);
                    tb_axim_rd_addr_in <= tb_axi_master_src_addr + i;
                    tb_axim_rd_en_in   <= 1;
                    
                    @(posedge tb_clk); // 1 拍地址
                    @(posedge tb_clk); // 1 拍数据
                    tb_axim_rd_en_in <= 0;
                    
                    // 保存结果行
                    for (int j = 0; j < TEST_N; j++) begin
                        ddr_results[i][j] = tb_axim_rd_data_out[j];
                    end
                end
                
                $display("[%0t] TB: AXI Master DMA Finished. Sending done IRQ.", $time);
                // 发送 "完成" 中断
                @(posedge tb_clk);
                tb_axi_master_done_irq <= 1;
                @(posedge tb_clk);
                tb_axi_master_done_irq <= 0;
            end
        join_none

        // --- 7. 轮询 "Done" 状态 (模拟 CPU) ---
        $display("[%0t] TB: CPU polling for Done pulse...", $time);
        status_reg = 0;
        while (status_reg[1] == 0) begin // 等待 'done_pulse' bit
            csr_read(8'h04, status_reg); // ADDR_STATUS
        end
        $display("[%0t] TB: *** TPU DONE *** Done pulse received!", $time);
        
        // --- 8. 检查结果 ---
        $display("[%0t] TB: --- Checking Results ---", $time);
        for (int i = 0; i < TEST_M; i++) begin
            for (int j = 0; j < TEST_N; j++) begin
                if (ddr_results[i][j] !== D_golden[i][j]) begin
                    $display("[%0t] TB: ERROR! D[%0d][%0d]: Expected %d, Got %d",
                             $time, i, j, D_golden[i][j], ddr_results[i][j]);
                    errors++;
                end
            end
        end

        // --- 9. 最终报告 ---
        #100; // 等待波形稳定
        if (errors == 0) begin
            $display("[%0t] TB: ***--- TEST PASSED ---***", $time);
        end else begin
            $display("[%0t] TB: ***--- TEST FAILED (Errors: %0d) ---***", $time, errors);
        end
        
        $finish;
        
    end

endmodule
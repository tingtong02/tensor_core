`timescale 1ns/1ps
`default_nettype none

module tb_verification_top;

    // --- 1. Testbench 参数 ---
    localparam W                = 4;   // <-- 测试 4x4 阵列
    localparam DATA_WIDTH_IN    = 8;
    localparam DATA_WIDTH_ACCUM = 32;
    localparam ADDR_WIDTH       = 10;
    localparam CSR_ADDR_WIDTH   = 8;
    localparam CLK_PERIOD       = 1.0; // 1GHz

    // --- 2. 时钟和复位 ---
    logic clk;
    logic rst;

    // --- 3. DUT 接口 ---
    // AXI-Lite (CSR)
    logic [CSR_ADDR_WIDTH-1:0] csr_addr;
    logic                      csr_wr_en;
    logic [31:0]               csr_wr_data;
    logic                      csr_rd_en;
    logic [31:0]               csr_rd_data;
    
    // AXI-Master
    logic                         axi_master_start_pulse;
    logic [31:0]                  axi_master_dest_addr;
    logic [ADDR_WIDTH-1:0]      axi_master_src_addr;
    logic [15:0]                  axi_master_length;
    logic                         axi_master_done_irq;
    logic [ADDR_WIDTH-1:0]       axim_rd_addr_in;
    logic                        axim_rd_en_in;
    logic [DATA_WIDTH_ACCUM-1:0] axim_rd_data_out [W];

    // Host Write
    logic [ADDR_WIDTH-1:0]       host_wr_addr_in;
    logic                        host_wr_en_in;
    logic [DATA_WIDTH_ACCUM-1:0] host_wr_data_in [W];
    
    // --- 4. 实例化 DUT ---
    tpu_verification_top #(
        .SYSTOLIC_ARRAY_WIDTH(W),
        .DATA_WIDTH_IN(DATA_WIDTH_IN),
        .DATA_WIDTH_ACCUM(DATA_WIDTH_ACCUM),
        .ADDR_WIDTH(ADDR_WIDTH),
        .CSR_ADDR_WIDTH(CSR_ADDR_WIDTH)
    ) dut (
        .clk(clk),
        .rst(rst),
        .* // 自动连接同名信号
    );

    // --- 5. 时钟生成 ---
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // --- 6. 辅助任务 (Tasks) ---
    task wait_clk(input int N);
        repeat (N) @(posedge clk);
    endtask

    // 任务: AXI-Lite 写入
    task axi_lite_write(input [CSR_ADDR_WIDTH-1:0] addr, input [31:0] data);
        @(posedge clk);
        csr_addr    = addr;
        csr_wr_data = data;
        csr_wr_en   = 1;
        @(posedge clk);
        csr_wr_en   = 0;
    endtask
    
    // 任务: Host 写入 Input Buffer
    task host_write(input [ADDR_WIDTH-1:0] addr, input [DATA_WIDTH_ACCUM-1:0] data[W]);
        @(posedge clk);
        host_wr_addr_in = addr;
        host_wr_data_in = data;
        host_wr_en_in   = 1;
        @(posedge clk);
        host_wr_en_in   = 0;
    endtask

    // ========================================================================
    // --- 7. Testbench 黄金数据和变量 (模块作用域) ---
    // ========================================================================
    localparam int K_DIM = 2;
    localparam int M_DIM = 2;
    localparam int N_DIM = 2;
    
    // 延迟计算: L_C (C-Flow) = 2*K
    localparam int L_C = 2 * K_DIM;
    // 延迟计算: L_D (D-Flow) = 2*K + W
    localparam int L_D = (2 * K_DIM) + W;

    logic [DATA_WIDTH_ACCUM-1:0] row_a_0, row_a_1, row_b_0, row_b_1, row_c_0, row_c_1;
    logic [DATA_WIDTH_ACCUM-1:0] golden_d_0, golden_d_1;

    // ========================================================================
    // 8. 主测试序列
    // ========================================================================
    initial begin
        // --- 关键修复: 变量声明必须在所有执行语句之前 ---
        logic [15:0] total_reads;
        
        $display("TB: Simulation Started.");
        
        // --- 初始化复位 ---
        rst = 1;
        csr_wr_en   = 0;
        host_wr_en_in   = 0;
        axi_master_done_irq = 0;
        axim_rd_en_in = 0;
        wait_clk(5);
        rst = 0;
        wait_clk(1);
        $display("TB: [%0t] Reset Released.", $time);

        // --- 黄金数据定义 ---
        // A(M=2, K=2) = [[10, 20], [30, 40]]
        // B(K=2, N=2) = [[1, 2], [3, 4]]
        // C(M=2, N=2) = [[1, 1], [1, 1]]
        // D(M=2, N=2) = [[71, 101], [151, 221]]
        
        // 打包数据
        row_a_0[0] = 32'd10; row_a_0[1] = 32'd20; // A[0]
        row_a_1[0] = 32'd30; row_a_1[1] = 32'd40; // A[1]
        row_b_0[0] = 32'd1;  row_b_0[1] = 32'd2;  // B[0]
        row_b_1[0] = 32'd3;  row_b_1[1] = 32'd4;  // B[1]
        row_c_0[0] = 32'd1;  row_c_0[1] = 32'd1;  // C[0]
        row_c_1[0] = 32'd1;  row_c_1[1] = 32'd1;  // C[1]
        
        golden_d_0[0] = 32'd71; golden_d_0[1] = 32'd101; // D[0]
        golden_d_1[0] = 32'd151; golden_d_1[1] = 32'd221; // D[1]

        // --- 1. Host 写入 Input Buffer ---
        $display("TB: [%0t] Phase 1: Host writing data to Input Buffer...", $time);
        host_write(10, row_a_0); // Addr 10: A[0]
        host_write(11, row_a_1); // Addr 11: A[1]
        host_write(20, row_b_0); // Addr 20: B[0]
        host_write(21, row_b_1); // Addr 21: B[1]
        host_write(30, row_c_0); // Addr 30: C[0]
        host_write(31, row_c_1); // Addr 31: C[1]

        // --- 2. Host 配置 Control Unit (CSRs) ---
        $display("TB: [%0t] Phase 2: Host writing configuration...", $time);
        axi_lite_write(8'h10, M_DIM); // ADDR_DIM_M
        axi_lite_write(8'h14, K_DIM); // ADDR_DIM_K
        axi_lite_write(8'h18, N_DIM); // ADDR_DIM_N
        axi_lite_write(8'h20, 10);    // ADDR_A
        axi_lite_write(8'h24, 20);    // ADDR_B
        axi_lite_write(8'h28, 30);    // ADDR_C
        axi_lite_write(8'h2C, 40);    // ADDR_D (Output Buffer Addr)
        axi_lite_write(8'h30, 32'h80000000); // ADDR_DDR (Ext Memory)
        axi_lite_write(8'h34, 3'b001); // VPU_MODE (Enable Bias Add)
        axi_lite_write(8'h38, L_C); // LATENCY_C
        axi_lite_write(8'h3C, L_D); // LATENCY_D

        // --- 3. 触发计算 ---
        $display("TB: [%0t] Phase 3: Triggering Start...", $time);
        axi_lite_write(8'h00, 32'd1); // ADDR_CONTROL -> START
        
        // --- 4. 等待 AXI Master 启动信号 ---
        $display("TB: [%0t] Phase 4: Computation running, waiting for Master...", $time);
        wait_clk(50); // 等待计算完成 (50 拍足够)
        @(posedge axi_master_start_pulse);
        $display("TB: [%0t] ... AXI Master start pulse received!", $time);

        // --- 5. 模拟 AXI Master 读取结果 ---
        $display("TB: [%0t] Phase 5: Simulating AXI Master reading from Output Buffer...", $time);
        
        total_reads = axi_master_length; // 赋值语句保留在这里
        
        // 循环读取 M*N 行 (在我们的架构中是 M 行，因为 N 是并行输出的)
        for (int i = 0; i < M_DIM; i++) begin
            @(posedge clk);
            axim_rd_addr_in = axi_master_src_addr + i;
            axim_rd_en_in   = 1;
            @(posedge clk);
            axim_rd_en_in = 0;
            
            // 检查读出的数据
            if (i == 0) begin // 检查 D[0]
                if (axim_rd_data_out[0] == golden_d_0[0] && axim_rd_data_out[1] == golden_d_0[1])
                    $display("TB: [%0t] \033[0;32mPASS\033[0m - Row D[0] correct.", $time);
                else
                    $error("TB: [%0t] \033[0;31mFAIL\033[0m - Row D[0] incorrect. Got: %h, %h", $time, axim_rd_data_out[0], axim_rd_data_out[1]);
            end
            if (i == 1) begin // 检查 D[1]
                if (axim_rd_data_out[0] == golden_d_1[0] && axim_rd_data_out[1] == golden_d_1[1])
                    $display("TB: [%0t] \033[0;32mPASS\033[0m - Row D[1] correct.", $time);
                else
                    $error("TB: [%0t] \033[0;31mFAIL\033[0m - Row D[1] incorrect. Got: %h, %h", $time, axim_rd_data_out[0], axim_rd_data_out[1]);
            end
        end

        // --- 6. 模拟 AXI Master 完成握手 ---
        $display("TB: [%0t] Phase 6: Simulating AXI Master Done IRQ...", $time);
        @(posedge clk);
        axi_master_done_irq = 1;
        @(posedge clk);
        axi_master_done_irq = 0;

        // --- 7. 检查是否返回 IDLE ---
        wait_clk(5);
        
        csr_rd_en = 1;
        csr_addr = 8'h04; // ADDR_STATUS
        @(posedge clk);
        
        if (csr_rd_data[0] == 1'b0) // BUSY bit
            $display("TB: [%0t] \033[0;32mPASS\033[0m - TPU returned to IDLE (BUSY=0).", $time);
        else
            $error("TB: [%0t] \033[0;31mFAIL\033[0m - TPU did not return to IDLE (BUSY=1).", $time);
        
        csr_rd_en = 0;

        $display("TB: [%0t] Simulation Finished.", $time);
        $finish;
    end

endmodule
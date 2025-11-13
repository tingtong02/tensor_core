`timescale 1ns/1ps

module tb_bias_child;

    // ==========================================
    // 1. 参数与信号定义
    // ==========================================
    parameter int DATA_WIDTH = 32;

    // 时钟与复位
    logic clk;
    logic rst;

    // DUT 输入 (激励信号)
    logic signed [DATA_WIDTH-1:0] bias_scalar_in;
    logic signed [DATA_WIDTH-1:0] bias_sys_data_in;
    logic                         bias_sys_valid_in;

    // DUT 输出 (观察信号)
    logic signed [DATA_WIDTH-1:0] bias_z_data_out;
    logic                         bias_Z_valid_out;

    // ==========================================
    // 2. 实例化 DUT (Device Under Test)
    // ==========================================
    bias_child #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_dut (
        .clk              (clk),
        .rst              (rst),
        .bias_scalar_in   (bias_scalar_in),
        .bias_sys_data_in (bias_sys_data_in),
        .bias_sys_valid_in(bias_sys_valid_in),
        .bias_z_data_out  (bias_z_data_out),
        .bias_Z_valid_out (bias_Z_valid_out)
    );

    // ==========================================
    // 3. 时钟生成 (100MHz, 10ns 周期)
    // ==========================================
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // ==========================================
    // 4. 主测试流程 (Main Test Sequence)
    // ==========================================
    initial begin
        // --- A. 系统初始化 (Initialization) ---
        $display("=== Simulation Start ===");
        bias_scalar_in    = '0;
        bias_sys_data_in  = '0;
        bias_sys_valid_in = 1'b0;
        rst               = 1'b1; // 断言复位

        // --- B. 释放复位 (Reset Release) ---
        #20;
        @(posedge clk); 
        rst = 1'b0;       // 释放复位
        $display("[Time %0t] Reset Released", $time);
        #20;              // 等待电路稳定

        // ==========================================
        // 测试场景 1: 单次基本加法 (Basic Addition)
        // 目标: 5 (Systolic) + 10 (Scalar) = 15
        // ==========================================
        $display("\n--- Test Case 1: Basic Addition (5 + 10) ---");
        
        // 1.1 驱动输入
        @(posedge clk);
        bias_sys_valid_in <= 1'b1;      // 有效标记
        bias_sys_data_in  <= 32'sd5;    // 输入 5
        bias_scalar_in    <= 32'sd10;   // 输入 10 (Bias)

        // 1.2 停止驱动 (插入气泡)
        @(posedge clk);
        bias_sys_valid_in <= 1'b0;      // 拉低 Valid
        bias_sys_data_in  <= '0;        // 清零数据线

        // 1.3 检查输出 (Latency = 1 cycle)
        // 在上面的沿，DUT 采样了输入；在这个沿，DUT 应该输出结果
        @(posedge clk); 
        
        // 自动检查结果
        if (bias_z_data_out === 32'sd15 && bias_Z_valid_out === 1'b1) begin
            $display("[PASS] TC1: Output is 15, Valid is High.");
        end else begin
            $error("[FAIL] TC1: Expected 15, got %d. Valid: %b", bias_z_data_out, bias_Z_valid_out);
        end
        
        // 等待几个周期，确保输出变回无效
        repeat(2) @(posedge clk);


        // ==========================================
        // 测试场景 2: 连续数据流与气泡 (Stream & Bubble)
        // 目标: 验证流水线吞吐率和 Valid 信号控制
        // 序列: (10+1) -> (20+1) -> [Bubble] -> (30+1)
        // ==========================================
        $display("\n--- Test Case 2: Stream Data with Bubble ---");
        
        // 保持 Bias 为 1
        bias_scalar_in <= 32'sd1; 

        // 2.1 发送数据 10 (T0)
        @(posedge clk);
        bias_sys_valid_in <= 1'b1;
        bias_sys_data_in  <= 32'sd10; 
        $display("[Time %0t] Driving Input: 10", $time);

        // 2.2 发送数据 20 (T1) - 紧接着上一个
        @(posedge clk);
        bias_sys_valid_in <= 1'b1;
        bias_sys_data_in  <= 32'sd20;
        $display("[Time %0t] Driving Input: 20", $time);

        // 2.3 插入气泡 (T2) - Valid 拉低
        @(posedge clk);
        bias_sys_valid_in <= 1'b0;
        bias_sys_data_in  <= 32'sd0; // 数据无关紧要
        $display("[Time %0t] Driving Input: Bubble (Valid=0)", $time);

        // 2.4 发送数据 30 (T3) - 恢复发送
        @(posedge clk);
        bias_sys_valid_in <= 1'b1;
        bias_sys_data_in  <= 32'sd30;
        $display("[Time %0t] Driving Input: 30", $time);

        // 2.5 结束发送
        @(posedge clk);
        bias_sys_valid_in <= 1'b0;
        bias_sys_data_in  <= '0;

        // 2.6 观察期
        // 我们预期输出顺序为: 11 -> 21 -> (无效) -> 31
        repeat(5) @(posedge clk);

        $display("\n=== Simulation Finished ===");
        $finish;
    end

    // ==========================================
    // 5. 监控器 (Monitor)
    // ==========================================
    // 使用 monitor 实时打印信号变化，方便调试波形
    initial begin
        $monitor("Time=%0t | In: Valid=%b Data=%d | Out: Valid=%b Data=%d",
                 $time, bias_sys_valid_in, bias_sys_data_in, bias_Z_valid_out, bias_z_data_out);
    end

endmodule
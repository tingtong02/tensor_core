`timescale 1ns/1ps
`default_nettype none

module tb_systolic;

    // --- 1. Testbench 参数 ---
    localparam W                = 4; 
    localparam DATA_WIDTH_IN    = 8;
    localparam DATA_WIDTH_ACCUM = 32;
    localparam CLK_PERIOD       = 1.0; // 1ns = 1GHz 目标

    // --- 2. 时钟和复位 ---
    logic clk;
    logic rst;

    // 时钟生成
    initial begin
        clk = 0;
        forever #(CLK_PERIOD / 2) clk = ~clk; // 0.5ns 翻转
    end

    // --- 3. DUT 接口信号 ---
    logic signed [DATA_WIDTH_IN-1:0]   sys_data_in [W];
    logic                              sys_valid_in [W];
    logic                              sys_switch_in [W];
    logic signed [DATA_WIDTH_IN-1:0]   sys_weight_in [W];
    logic [$clog2(W)-1:0]              sys_index_in [W];
    logic                              sys_accept_w_in [W];
    logic [W-1:0]                      sys_enable_rows; // K 掩码
    logic [W-1:0]                      sys_enable_cols; // M 掩码

    logic signed [DATA_WIDTH_ACCUM-1:0] sys_data_out [W];
    logic                               sys_valid_out [W];

    // --- 4. 实例化 DUT (Device Under Test) ---
    systolic #(
        .SYSTOLIC_ARRAY_WIDTH(W),
        .DATA_WIDTH_IN(DATA_WIDTH_IN),
        .DATA_WIDTH_ACCUM(DATA_WIDTH_ACCUM)
    ) dut (
        .clk(clk),
        .rst(rst),
        .* // 自动连接同名信号
    );

    // --- 5. 辅助任务 (Tasks) ---

    // 等待 N 个时钟周期
    task wait_clk(input int N);
        repeat (N) @(posedge clk);
    endtask

    // 初始化所有输入端口 (已修改为使用 for 循环以兼容 iverilog)
    task init_inputs;
        integer i;
        for (i = 0; i < W; i = i + 1) begin
            sys_data_in[i]     = '0;
            sys_valid_in[i]    = '0;
            sys_switch_in[i]   = '0;
            sys_weight_in[i]   = '0;
            sys_index_in[i]    = '0;
            sys_accept_w_in[i] = '0;
        end
        sys_enable_rows = '0;
        sys_enable_cols = '0;
    endtask

    // --- 6. 主测试序列 (已修正复位逻辑) ---
    initial begin
        $display("TB: Simulation Started.");

        // 告诉模拟器将波形保存到 "waveform.vcd" 文件
        $dumpfile("wave_sys.vcd"); 
        // "0" 表示转储 tb_systolic 模块及其所有子模块 (即 dut) 中的所有信号
        $dumpvars(0, tb_systolic); 
        // --- 波形转储代码结束 ---
        
        // --- 关键修复: 在 t=0 时立即初始化所有信号 ---
        // 确保 rst=1 在第一个时钟沿 (t=0.5ns) 之前
        rst = 1;
        init_inputs();
        
        // 执行复位
        $display("TB: [%0t] Applying Reset...", $time);
        wait_clk(5); // 保持复位 5 个周期
        rst = 0;
        wait_clk(1); // 保持 rst=0 一个周期
        $display("TB: [%0t] Reset Released.", $time);
        // --- 复位在 t=6ns (6000ps) 结束 ---

        // --- Test Case 1: 2x2 * 2x2 (使用 W=4 阵列) ---
        // A = [[1, 2], [3, 4]]  (M=2, K=2)
        // B = [[10, 20], [30, 40]] (K=2, N=2)
        // E = [[70, 100], [150, 220]]
        
        sys_enable_rows = 4'b0011; // 启用 PE[0][j] 和 PE[1][j]
        sys_enable_cols = 4'b0011; // 启用 PE[i][0] 和 PE[i][1]

        $display("TB: [%0t] TEST 1: Loading A1 (K=2, M=2)", $time);

        // --- 阶段 1: 加载 A 矩阵 (权重) ---
        // (t=6ns)
        sys_accept_w_in[0] = 1; sys_weight_in[0] = 2; sys_index_in[0] = 1; // A[0][1]
        sys_accept_w_in[1] = 0; sys_weight_in[1] = 0; sys_index_in[1] = 0;
        sys_switch_in[0] = 0; sys_valid_in[0] = 0; sys_data_in[0] = 0;
        sys_switch_in[1] = 0; sys_valid_in[1] = 0; sys_data_in[1] = 0;
        @(posedge clk); // t=7ns

        // (t=7ns)
        sys_accept_w_in[0] = 1; sys_weight_in[0] = 1; sys_index_in[0] = 0; // A[0][0]
        sys_accept_w_in[1] = 1; sys_weight_in[1] = 4; sys_index_in[1] = 1; // A[1][1]
        sys_switch_in[0] = 0; sys_valid_in[0] = 0; sys_data_in[0] = 0;
        sys_switch_in[1] = 0; sys_valid_in[1] = 0; sys_data_in[1] = 0;
        @(posedge clk); // t=8ns

        // (t=8ns)
        sys_accept_w_in[0] = 0; sys_weight_in[0] = 0; sys_index_in[0] = 0; 
        sys_accept_w_in[1] = 1; sys_weight_in[1] = 3; sys_index_in[1] = 0; // A[1][0]
        sys_switch_in[0] = 1; sys_valid_in[0] = 0; sys_data_in[0] = 0;
        sys_switch_in[1] = 0; sys_valid_in[1] = 0; sys_data_in[1] = 0;
        @(posedge clk); // t=9ns

        // (t=9ns)
        sys_accept_w_in[0] = 0; sys_weight_in[0] = 0; sys_index_in[0] = 0; 
        sys_accept_w_in[1] = 0; sys_weight_in[1] = 0; sys_index_in[1] = 0;
        sys_switch_in[0] = 0; sys_valid_in[0] = 1; sys_data_in[0] = 10;
        sys_switch_in[1] = 1; sys_valid_in[1] = 0; sys_data_in[1] = 0;
        @(posedge clk); // t=10ns

        // (t=10ns)
        sys_switch_in[0] = 0; sys_valid_in[0] = 1; sys_data_in[0] = 20;
        sys_switch_in[1] = 0; sys_valid_in[1] = 1; sys_data_in[1] = 30;
        @(posedge clk); // t=11ns

        // (t=11ns)
        sys_switch_in[0] = 0; sys_valid_in[0] = 0; sys_data_in[0] = 0;
        sys_switch_in[1] = 0; sys_valid_in[1] = 1; sys_data_in[1] = 40;
        @(posedge clk); // t=12ns
        

        $display("TB: [%0t] Inputs complete. Monitoring outputs.", $time);

        // 等待流水线清空
        wait_clk(10);
        $display("TB: [%0t] Simulation Finished.", $time);
        $finish;
    end
    
    // --- 7. 验证 (Checker / Monitor) ---

    
    always @(posedge clk) begin
        if (!rst) begin
            
            // --- 检查输出列 0 (E[0][*]) ---
            if ($time == 13ns) begin // 预期 E[0][0] = 70
                if (sys_valid_out[0] && sys_data_out[0] == 70)
                    $display("TB: [%0t] \033[0;32mPASS\033[0m - E[0][0] == 70", $time);
                else
                    $error("TB: [%0t] \033[0;31mFAIL\033[0m - E[0][0] != 70. Got: %d (Valid: %b)", $time, sys_data_out[0], sys_valid_out[0]);
            end
            
            if ($time == 14ns) begin // 预期 E[0][1] = 100
                if (sys_valid_out[0] && sys_data_out[0] == 100)
                    $display("TB: [%0t] \033[0;32mPASS\033[0m - E[0][1] == 100", $time);
                else
                    $error("TB: [%0t] \033[0;31mFAIL\033[0m - E[0][1] != 100. Got: %d (Valid: %b)", $time, sys_data_out[0], sys_valid_out[0]);
            end

            // --- 检查输出列 1 (E[1][*]) ---
            if ($time == 14ns) begin // 预期 E[1][0] = 150
                if (sys_valid_out[1] && sys_data_out[1] == 150)
                    $display("TB: [%0t] \033[0;32mPASS\033[0m - E[1][0] == 150", $time);
                else
                    $error("TB: [%0t] \033[0;31mFAIL\033[0m - E[1][0] != 150. Got: %d (Valid: %b)", $time, sys_data_out[1], sys_valid_out[1]);
            end
            
            if ($time == 15ns) begin // 预期 E[1][1] = 220
                if (sys_valid_out[1] && sys_data_out[1] == 220)
                    $display("TB: [%0t] \033[0;32mPASS\033[0m - E[1][1] == 220", $time);
                else
                    $error("TB: [%0t] \033[0;31mFAIL\033[0m - E[1][1] != 220. Got: %d (Valid: %b)", $time, sys_data_out[1], sys_valid_out[1]);
            end
            

        end
    end

endmodule
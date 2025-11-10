`timescale 1ns/1ps
`default_nettype none

module tb_systolic;

    // --- 参数 (Parameter) ---
    localparam int N = 2; // 测试 2x2 阵列

    // --- 信号 (Signals) ---
    logic clk;
    logic rst;

    // West Inputs
    logic signed [ 7:0] sys_data_in   [N-1:0];
    logic               sys_valid_in  [N-1:0];

    // North Inputs
    logic signed [ 7:0] sys_weight_in [N-1:0];
    logic               sys_accept_w  [N-1:0];

    // South Outputs
    logic signed [31:0] sys_data_out  [N-1:0];
    logic               sys_valid_out [N-1:0];

    // Control
    logic               sys_switch_in [N-1:0];
    logic [15:0]        ub_rd_col_size_in;
    logic               ub_rd_col_size_valid_in;

    // 迭代器
    integer i;
    
    // --- 实例化 DUT (Instantiate DUT) ---
    systolic #(
        .SYSTOLIC_ARRAY_WIDTH(N)
    ) uut (
        .clk(clk),
        .rst(rst),
        .sys_data_in(sys_data_in),
        .sys_valid_in(sys_valid_in),
        .sys_weight_in(sys_weight_in),
        .sys_accept_w(sys_accept_w),
        .sys_data_out(sys_data_out),
        .sys_valid_out(sys_valid_out),
        .sys_switch_in(sys_switch_in),
        .ub_rd_col_size_in(ub_rd_col_size_in),
        .ub_rd_col_size_valid_in(ub_rd_col_size_valid_in)
    );

    // --- 时钟 (Clock) ---
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 10ns 周期 (100MHz)
    end

    // --- 波形 (Waveform Dump for GTKWave) ---
    initial begin
        $dumpfile("systolic_wave.vcd");
        $dumpvars(0, uut); // Dump all signals inside uut
        $dumpvars(1, tb_systolic); // Dump testbench signals
    end

    // --- 激励 (Stimulus) ---
    initial begin
        $display("--- Systolic Testbench Start (N=%0d) ---", N);
        
        // --- 1. 复位 (Reset) ---
        rst = 1;
        ub_rd_col_size_in = 0;
        ub_rd_col_size_valid_in = 0;
        for (i = 0; i < N; i = i + 1) begin
            sys_data_in[i]   = 0;
            sys_valid_in[i]  = 0;
            sys_weight_in[i] = 0;
            sys_accept_w[i]  = 0;
            sys_switch_in[i] = 0;
        end
        repeat(2) @(posedge clk);
        rst = 0;
        $display("%0t: [Test 1] Reset released.", $time);

        // --- 2. 使能PE (Enable PE columns) ---
        @(posedge clk);
        ub_rd_col_size_in = N; // 启用所有 N=2 列
        ub_rd_col_size_valid_in = 1;
        $display("%0t: [Test 2] Enabling %0d PE columns.", $time, N);
        
        @(posedge clk);
        ub_rd_col_size_valid_in = 0;

        // --- 3. 加载权重 (Load Weights) ---
        // 目标权重 (B 矩阵):
        // W[0,0]=2, W[0,1]=3
        // W[1,0]=4, W[1,1]=5
        
        // 周期 A: 加载 [4, 5] (将进入第 1 行)
        @(posedge clk);
        sys_weight_in[0] = 4; // W10
        sys_weight_in[1] = 5; // W11
        for (i = 0; i < N; i = i + 1) sys_accept_w[i] = 1;
        $display("%0t: [Test 3] Loading weights [4, 5] (for row 1).", $time);

        // 周期 B: 加载 [2, 3] (将进入第 0 行).
        //          权重 [4, 5] 同时被推到第 1 行.
        @(posedge clk);
        sys_weight_in[0] = 2; // W00
        sys_weight_in[1] = 3; // W01
        $display("%0t: [Test 3] Loading weights [2, 3] (for row 0).", $time);

        @(posedge clk);
        for (i = 0; i < N; i = i + 1) sys_accept_w[i] = 0;
        $display("%0t: [Test 3] Weight loading finished. Inactive regs loaded.", $time);
        
        // --- 4. 切换权重 (Switch Weights) ---
        // 切换信号自西向东传播 (需要 N 个周期)
        
        // 周期 C: 启动切换脉冲
        @(posedge clk);
        for (i = 0; i < N; i = i + 1) sys_switch_in[i] = 1;
        $display("%0t: [Test 4] Assert sys_switch_in. Col 0 (PEs [0,0], [1,0]) switch.", $time);

        // 周期 D: 停止脉冲. 切换信号传播到 Col 1
        @(posedge clk);
        for (i = 0; i < N; i = i + 1) sys_switch_in[i] = 0;
        $display("%0t: [Test 4] De-assert sys_switch_in. Col 1 (PEs [0,1], [1,1]) switch.", $time);
        
        @(posedge clk);
        // 此时 (周期 E), N=2 列已全部切换.
        // Active Weights 应为:
        // PE(0,0)=2, PE(0,1)=3
        // PE(1,0)=4, PE(1,1)=5
        $display("%0t: [Test 4] Weight switch finished. All PEs active.", $time);


        // --- 5. 运行计算 (Run Computation) ---
        // A 矩阵 = [10, 1], [20, 2]
        // B 矩阵 = [2, 3], [4, 5]
        // D = A * B = [ (10*2+1*4), (10*3+1*5) ] = [ 24,  35]
        //             [ (20*2+2*4), (20*3+2*5) ] = [ 48,  70]
        
        // *** 我们的阵列计算 D = A * B_transpose, 或说 B 是权重, D = A * B ***
        // 假设 A 是输入, B 是权重.
        // A = [10, 1]  (A_row0)
        //     [20, 2]  (A_row1)
        // B = [ 2, 3]  (W_col0, W_col1)
        //     [ 4, 5]
        //
        // D[0,0] = A[0,0]*W[0,0] + A[0,1]*W[1,0] = 10*2 + 1*4 = 24
        // D[0,1] = A[0,0]*W[0,1] + A[0,1]*W[1,1] = 10*3 + 1*5 = 35
        // D[1,0] = A[1,0]*W[0,0] + A[1,1]*W[1,0] = 20*2 + 2*4 = 48
        // D[1,1] = A[1,0]*W[0,1] + A[1,1]*W[1,1] = 20*3 + 2*5 = 70
        //
        // 阵列输出 D 的转置 (按列输出)
        // sys_data_out[0] (D_col0) 应在 T3, T4... 依次输出 [24, 48]
        // sys_data_out[1] (D_col1) 应在 T4, T5... 依次输出 [35, 70]
        
        
        // --- 激励: 倾斜输入 A 矩阵 ---
        // (T = 0 是指这个激励块的第一个周期)
        
        // T=0
        @(posedge clk);
        sys_data_in[0] = 10; // A[0][0]
        sys_valid_in[0] = 1;
        $display("%0t: [Test 5] Input A[0][0] = 10", $time);

        // T=1
        @(posedge clk);
        sys_data_in[0] = 1;  // A[0][1]
        sys_valid_in[0] = 1;
        sys_data_in[1] = 20; // A[1][0]
        sys_valid_in[1] = 1;
        $display("%0t: [Test 5] Input A[0][1] = 1, A[1][0] = 20", $time);
        
        // T=2
        @(posedge clk);
        sys_data_in[0] = 0;  // A[0][2] (padding)
        sys_valid_in[0] = 0;
        sys_data_in[1] = 2;  // A[1][1]
        sys_valid_in[1] = 1;
        $display("%0t: [Test 5] Input A[1][1] = 2", $time);

        // T=3: 最后一个有效输入. 第一个结果 D[0,0] 应该在 T=3+N=5 出现
        @(posedge clk);
        sys_data_in[1] = 0; // A[1][2] (padding)
        sys_valid_in[1] = 0;
        $display("%0t: [Test 5] Input finished.", $time);
        
        // 等待流水线清空 (N for East-West + N for North-South)
        // N=2, 需要 2+2=4 个周期. 我们等待 6 个周期.
        $display("%0t: [Test 5] Waiting 6 cycles for pipeline to clear...", $time);
        
        @(posedge clk); // T=4
        $display("%0t: Pipeline: D_col0=%0d, D_col1=%0d", $time, sys_data_out[0], sys_data_out[1]);

        @(posedge clk); // T=5. D[0,0]=24 (col0) 和 D[0,1]=35 (col1) 应该出现
        $display("%0t: --- Result Check 1 ---", $time);
        $display("%0t: sys_data_out[0] = %d (Expected 24)", $time, sys_data_out[0]);
        $display("%0t: sys_data_out[1] = %d (Expected 35)", $time, sys_data_out[1]);
        $display("%0t: sys_valid_out[0]= %b, sys_valid_out[1]= %b", $time, sys_valid_out[0], sys_valid_out[1]);

        @(posedge clk); // T=6. D[1,0]=48 (col0) 和 D[1,1]=70 (col1) 应该出现
        $display("%0t: --- Result Check 2 ---", $time);
        $display("%0t: sys_data_out[0] = %d (Expected 48)", $time, sys_data_out[0]);
        $display("%0t: sys_data_out[1] = %d (Expected 70)", $time, sys_data_out[1]);
        $display("%0t: sys_valid_out[0]= %b, sys_valid_out[1]= %b", $time, sys_valid_out[0], sys_valid_out[1]);

        @(posedge clk); // T=7. 流水线清空, 输出应为 0
        $display("%0t: --- Result Check 3 (Flush) ---", $time);
        $display("%0t: sys_data_out[0] = %d (Expected 0)", $time, sys_data_out[0]);
        $display("%0t: sys_data_out[1] = %d (Expected 0)", $time, sys_data_out[1]);
        $display("%0t: sys_valid_out[0]= %b, sys_valid_out[1]= %b", $time, sys_valid_out[0], sys_valid_out[1]);

        @(posedge clk);
        $display("--- Testbench End ---");
        $stop;
    end

endmodule
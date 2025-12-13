`timescale 1ns/1ps

module tb_vpu;

    // ==========================================
    // 1. 参数配置 (VPU_WIDTH = 4 用于仿真演示)
    // ==========================================
    parameter int VPU_WIDTH     = 4; 
    parameter int DATA_WIDTH_IN = 32;

    // 时钟与复位
    logic clk;
    logic rst;

    // --- 控制信号 ---
    logic [2:0] vpu_mode;

    // --- 向量输入 (Unpacked Arrays) ---
    logic signed [DATA_WIDTH_IN-1:0] vpu_sys_data_in  [VPU_WIDTH];
    logic                            vpu_sys_valid_in [VPU_WIDTH];
    logic signed [DATA_WIDTH_IN-1:0] vpu_bias_data_in [VPU_WIDTH];

    // --- 向量输出 ---
    logic signed [DATA_WIDTH_IN-1:0] vpu_data_out [VPU_WIDTH];
    logic                            vpu_valid_out [VPU_WIDTH];

    // ==========================================
    // 2. 实例化 DUT
    // ==========================================
    vpu #(
        .VPU_WIDTH    (VPU_WIDTH),
        .DATA_WIDTH_IN(DATA_WIDTH_IN)
    ) u_dut (
        .clk              (clk),
        .rst              (rst),
        .vpu_mode         (vpu_mode), // 目前逻辑直通，但最好给固定值
        .vpu_sys_data_in  (vpu_sys_data_in),
        .vpu_sys_valid_in (vpu_sys_valid_in),
        .vpu_bias_data_in (vpu_bias_data_in),
        .vpu_data_out     (vpu_data_out),
        .vpu_valid_out    (vpu_valid_out)
    );

    // ==========================================
    // 3. 时钟生成 (100MHz)
    // ==========================================
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // ==========================================
    // 4. 辅助任务: 向量驱动器 (Driver Task)
    // ==========================================
    // 这个 Task 让我们能够一行代码同时控制 4 个 Lane
    task automatic drive_vector(
        input logic [VPU_WIDTH-1:0] valid_mask, // 掩码: 4'b1010 表示 Lane 3,1 有效
        input int                   base_sys,   // Systolic 数据基准值
        input int                   base_bias   // Bias 数据基准值
    );
        // 配合时钟沿驱动
        @(posedge clk);
        foreach (vpu_sys_data_in[i]) begin
            if (valid_mask[i]) begin
                // 如果该 Lane 有效: 赋值并拉高 Valid
                vpu_sys_valid_in[i] <= 1'b1;
                // 这里为了演示，让每个 Lane 的数据递增: Lane[i] = Base + i
                vpu_sys_data_in[i]  <= base_sys + i;  
                vpu_bias_data_in[i] <= base_bias + i; 
            end else begin
                // 如果该 Lane 无效 (气泡): 清零 Valid
                vpu_sys_valid_in[i] <= 1'b0;
                vpu_sys_data_in[i]  <= '0;
                vpu_bias_data_in[i] <= '0;
            end
        end
    endtask

    // ==========================================
    // 5. 主测试流程 (Main Sequence)
    // ==========================================
    initial begin
        // --- A. 初始化 ---
        $display("=== VPU Simulation Start (Width=%0d) ===", VPU_WIDTH);
        foreach (vpu_sys_data_in[i]) begin
            vpu_sys_data_in[i]  = '0;
            vpu_bias_data_in[i] = '0;
            vpu_sys_valid_in[i] = 1'b0;
        end
        vpu_mode = 3'b001; // Enable Add
        rst = 1'b1;

        // --- B. 释放复位 ---
        #20;
        rst = 1'b0;
        #20;

        // ==========================================
        // TC1: 并行计算测试 (All Lanes Active)
        // 目标: 所有通道同时计算
        // Lane 0: 10+5=15, Lane 1: 11+6=17, ...
        // ==========================================
        $display("\n--- TC1: Parallel Computation (Mask: 1111) ---");
        drive_vector(.valid_mask(4'b1111), .base_sys(10), .base_bias(5));
        
        // 插入一个全空闲周期 (All Bubbles) 以便观察
        drive_vector(.valid_mask(4'b0000), .base_sys(0), .base_bias(0));
        
        // 检查 TC1 结果 (应在 T+1 时刻出现)
        // 注意: drive_vector 内部已经消耗了一个 @(posedge clk)，所以此时已经是 T+1
        // 但由于是非阻塞赋值，我们要再等一个时钟沿去"观察"它的输出
        @(posedge clk); 
        if (vpu_data_out[0] === 15 && vpu_valid_out[0] === 1) 
            $display("[PASS] Lane 0 Correct: 15");
        else 
            $error("[FAIL] Lane 0 Expected 15, Got %d", vpu_data_out[0]);


        // ==========================================
        // TC2: 混合有效性测试 (Mixed Validity)
        // 目标: 测试独立控制。Mask = 4'b1010 (Lane 3 & 1 有效, 2 & 0 气泡)
        // ==========================================
        $display("\n--- TC2: Mixed Validity (Mask: 1010) ---");
        // Lane 1 Input: Sys=21, Bias=11 -> Expect 32
        // Lane 0 Input: Invalid (Bubble)
        drive_vector(.valid_mask(4'b1010), .base_sys(20), .base_bias(10));
        
        // 结束驱动
        drive_vector(.valid_mask(4'b0000), .base_sys(0), .base_bias(0));

        // 等待结果
        @(posedge clk);
        // 检查 Lane 1 (应有效)
        if (vpu_valid_out[1] === 1'b1 && vpu_data_out[1] === 32)
            $display("[PASS] Lane 1 Active (Res=32)");
        else
            $error("[FAIL] Lane 1 Expected Active/32, Got Valid=%b Val=%d", vpu_valid_out[1], vpu_data_out[1]);
            
        // 检查 Lane 0 (应无效)
        if (vpu_valid_out[0] === 1'b0)
            $display("[PASS] Lane 0 Bubble (Valid=0)");
        else
            $error("[FAIL] Lane 0 Expected Bubble, Got Valid=1");


        // ==========================================
        // TC3: 连续流压测 (Continuous Stream)
        // 目标: 模拟高负载，数据紧挨着数据
        // ==========================================
        $display("\n--- TC3: Continuous Stream Test ---");
        
        // T0: 发送第一包 (Mask 1111, Base 100)
        drive_vector(4'b1111, 100, 1); 
        
        // T1: 发送第二包 (Mask 1111, Base 200) - 紧接着上一个
        drive_vector(4'b1111, 200, 1);
        
        // T2: 发送第三包 (Mask 0101, Base 300) - 只有部分 Lane 有效
        drive_vector(4'b0101, 300, 1);
        
        // T3: 停止
        drive_vector(4'b0000, 0, 0);

        // 等待所有数据流出
        repeat(4) @(posedge clk);

        $display("\n=== Simulation Finished ===");
        $finish;
    end

    // ==========================================
    // 6. 智能监控 (只打印 Lane 0 和 Lane 1 以节省空间)
    // ==========================================
    initial begin
        $monitor("Time=%0t | L0_In(V:%b D:%d) -> L0_Out(V:%b D:%d) || L1_In(V:%b D:%d) -> L1_Out(V:%b D:%d)",
                 $time,
                 vpu_sys_valid_in[0], vpu_sys_data_in[0], vpu_valid_out[0], vpu_data_out[0],
                 vpu_sys_valid_in[1], vpu_sys_data_in[1], vpu_valid_out[1], vpu_data_out[1]);
    end

endmodule
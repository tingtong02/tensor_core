`timescale 1ns/1ps
`default_nettype none

/**
 * @brief Testbench for 'systolic' (Systolic Array)
 *
 * 包含一个 2x2 @ 4x4 (W=4) 的矩阵乘法测试用例。
 *
 * (已修正: 添加了 $monitor 的辅助信号，以兼容 Icarus Verilog)
 */
module tb_systolic;

    // --- 仿真参数 ---
    localparam int SYSTOLIC_ARRAY_WIDTH = 4;
    localparam int DATA_WIDTH_IN        = 8;
    localparam int DATA_WIDTH_ACCUM     = 32;
    
    // 简化别名
    localparam int W = SYSTOLIC_ARRAY_WIDTH;
    
    // 派生宽度
    localparam int INDEX_WIDTH          = $clog2(W);
    
    // 时钟周期 (10ns = 100MHz)
    localparam int CLK_PERIOD           = 10;

    // --- Testbench 信号 ---
    // 时钟与复位
    logic clk;
    logic rst;

    // --- DUT 输入 (来自左侧, 矩阵 B) ---
    logic signed [DATA_WIDTH_IN-1:0]   sys_data_in   [W];
    logic                              sys_valid_in  [W];
    logic                              sys_switch_in [W];

    // --- DUT 输入 (来自顶部, 矩阵 A 和 索引) ---
    logic signed [DATA_WIDTH_IN-1:0]   sys_weight_in [W];
    logic [INDEX_WIDTH-1:0]            sys_index_in  [W];
    logic                              sys_accept_w_in [W];

    // --- DUT 输出 (去往底部, 矩阵 E) ---
    logic signed [DATA_WIDTH_ACCUM-1:0] sys_data_out [W];
    logic                               sys_valid_out [W];

    // --- DUT 控制 ---
    logic [W-1:0] sys_enable_rows;
    logic [W-1:0] sys_enable_cols;

    // --- (新增) $monitor 辅助信号 ---
    // Icarus Verilog 不允许在 $monitor 中使用 $signed()
    // (修正: 明确使用 'wire' 类型以消除 'assign' 驱动歧义)
    wire signed [DATA_WIDTH_ACCUM-1:0] mon_signed_data_out_0;
    wire signed [DATA_WIDTH_ACCUM-1:0] mon_signed_data_out_1;


    // --- DUT 实例化 ---
    systolic #(
        .SYSTOLIC_ARRAY_WIDTH (W),
        .DATA_WIDTH_IN        (DATA_WIDTH_IN),
        .DATA_WIDTH_ACCUM     (DATA_WIDTH_ACCUM)
    ) uut (
        .clk                (clk),
        .rst                (rst),
        .sys_data_in        (sys_data_in),
        .sys_valid_in       (sys_valid_in),
        .sys_switch_in      (sys_switch_in),
        .sys_weight_in      (sys_weight_in),
        .sys_index_in       (sys_index_in),
        .sys_accept_w_in    (sys_accept_w_in),
        .sys_data_out       (sys_data_out),
        .sys_valid_out      (sys_valid_out),
        .sys_enable_rows    (sys_enable_rows),
        .sys_enable_cols    (sys_enable_cols)
    );

    // --- (新增) $monitor 辅助赋值 ---
    assign mon_signed_data_out_0 = $signed(sys_data_out[0]);
    assign mon_signed_data_out_1 = $signed(sys_data_out[1]);


    // --- 1. 时钟生成 ---
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // --- 2. 复位、激励与波形Dump ---
    initial begin
        // VCD 波形 Dump
        $dumpfile("tb_systolic.vcd");
        $dumpvars(0, tb_systolic); 

        // --- 复位阶段 ---
        @(negedge clk);
        $display("T=%0t: [TB] Applying Reset...", $time);
        rst = 1'b1;
        
        // 初始化所有输入
        sys_enable_rows = '0;
        sys_enable_cols = '0;
        for (int i = 0; i < W; i++) begin
            sys_data_in[i]     = '0;
            sys_valid_in[i]    = 1'b0;
            sys_switch_in[i]   = 1'b0;
            sys_weight_in[i]   = '0;
            sys_index_in[i]    = '0;
            sys_accept_w_in[i] = 1'b0;
        end

        #(CLK_PERIOD * 2);
        
        // --- 激励阶段 ---
        @(negedge clk);
        rst = 1'b0;
        $display("T=%0t: [TB] Releasing Reset.", $time);
        
        @(posedge clk); // T = 30ns

        // <-- [USER]: 用户的 2x2 矩阵乘法激励 -->
        
        // --- Test Case 1: 2x2 * 2x2 (使用 W=4 阵列) ---
        // A = [[1, 2], [3, 4]]  (M=2, K=2)
        // B = [[10, 20], [30, 40]] (K=2, N=2)
        // E = [[70, 100], [150, 220]]
        
        sys_enable_rows = 4'b0011; // 启用 PE[0][j] 和 PE[1][j]
        sys_enable_cols = 4'b0011; // 启用 PE[i][0] 和 PE[i][1]

 
        // (t=30ns)
        sys_accept_w_in[0] = 1; sys_weight_in[0] = 2; sys_index_in[0] = 1; // A[0][1] -> PE[1][0]
        sys_accept_w_in[1] = 0; sys_weight_in[1] = 0; sys_index_in[1] = 0;
        sys_switch_in[0] = 0; sys_valid_in[0] = 0; sys_data_in[0] = 0;
        sys_switch_in[1] = 0; sys_valid_in[1] = 0; sys_data_in[1] = 0;
        @(posedge clk); // t=40ns

        // 
        sys_accept_w_in[0] = 1; sys_weight_in[0] = 1; sys_index_in[0] = 0; // A[0][0] -> PE[0][0]
        sys_accept_w_in[1] = 1; sys_weight_in[1] = 4; sys_index_in[1] = 1; // A[1][1] -> PE[1][1]
        sys_switch_in[0] = 0; sys_valid_in[0] = 0; sys_data_in[0] = 0;
        sys_switch_in[1] = 0; sys_valid_in[1] = 0; sys_data_in[1] = 0;
        @(posedge clk); // t=50ns

        // 
        sys_accept_w_in[0] = 0; sys_weight_in[0] = 0; sys_index_in[0] = 0; 
        sys_accept_w_in[1] = 1; sys_weight_in[1] = 3; sys_index_in[1] = 0; // A[1][0] -> PE[0][1]
        sys_switch_in[0] = 1; sys_valid_in[0] = 0; sys_data_in[0] = 0;
        sys_switch_in[1] = 0; sys_valid_in[1] = 0; sys_data_in[1] = 0;
        @(posedge clk); // t=60ns

        //
        sys_accept_w_in[0] = 0; sys_weight_in[0] = 0; sys_index_in[0] = 0; 
        sys_accept_w_in[1] = 0; sys_weight_in[1] = 0; sys_index_in[1] = 0;
        sys_switch_in[0] = 0; sys_valid_in[0] = 1; sys_data_in[0] = 10; // B[0][0]
        sys_switch_in[1] = 1; sys_valid_in[1] = 0; sys_data_in[1] = 0;
        @(posedge clk); // t=70ns

        //
        sys_switch_in[0] = 0; sys_valid_in[0] = 1; sys_data_in[0] = 20; // B[0][1]
        sys_switch_in[1] = 0; sys_valid_in[1] = 1; sys_data_in[1] = 30; // B[1][0]
        @(posedge clk); // t=80ns

        //
        sys_switch_in[0] = 0; sys_valid_in[0] = 0; sys_data_in[0] = 0;
        sys_switch_in[1] = 0; sys_valid_in[1] = 1; sys_data_in[1] = 40; // B[1][1]
        @(posedge clk); // t=90ns

        // (清除输入，等待 Psum 流出)
        sys_valid_in[0] = 0;
        sys_valid_in[1] = 0;
        
        $display("T=%0t: [TB] All stimuli injected. Waiting for Psum propagation...", $time);
        
        // 增加足够的延迟让结果流出 4 个PE (2个使能, 2个禁用直通)
        #(100 * CLK_PERIOD);
        
        $display("T=%0t: [TB] Test complete.", $time);
        $finish; // 结束仿真
    end

    // --- 3. 信号监控 (针对 W=4 和 2x2 结果) ---
    initial begin
        @(negedge rst); // 等待复位结束
        
        // (已修正: 使用辅助信号)
        $monitor(
            "T=%0t [RST=%b] | (OUT[0]) Vld=%b Data=%6d | (OUT[1]) Vld=%b Data=%6d",
            $time, rst,
            sys_valid_out[0], mon_signed_data_out_0, // <-- (已修正)
            sys_valid_out[1], mon_signed_data_out_1  // <-- (已修正)
        );
    end

endmodule
`default_nettype wire // 恢复默认值
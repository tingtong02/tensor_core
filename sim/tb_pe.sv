`timescale 1ns/1ps
`default_nettype none

/**
 * @brief Testbench for 'pe' (Processing Element)
 *
 * 包含一个自动化的测试激励序列，用于验证:
 * 1. Reset
 * 2. PE Disabled (Psum Passthrough)
 * 3. A-Flow FSM (Eat, Propagate, Stop)
 * 4. MAC Calculation
 * 5. Double Buffering (Weight Switching)
 */
module tb_pe;

    // --- 仿真参数 ---
    localparam int ROW_ID               = 0; // 必须匹配 Test 3.2 的激励
    localparam int SYSTOLIC_ARRAY_WIDTH = 16;
    localparam int DATA_WIDTH_IN        = 8;
    localparam int DATA_WIDTH_ACCUM     = 32;
    
    // DUT 中使用的派生宽度
    localparam int INDEX_WIDTH          = $clog2(SYSTOLIC_ARRAY_WIDTH);
    
    // 时钟周期 (10ns = 100MHz)
    localparam int CLK_PERIOD           = 10;

    // --- Testbench 信号 ---
    // 时钟与复位
    logic clk;
    logic rst;

    // DUT 输入 (Inputs)
    logic pe_valid_in;
    logic pe_switch_in;
    logic pe_enabled;
    logic pe_accept_w_in;
    logic signed [DATA_WIDTH_IN-1:0]     pe_weight_in;
    logic [INDEX_WIDTH-1:0]              pe_index_in;
    logic signed [DATA_WIDTH_ACCUM-1:0]  pe_psum_in;
    logic                                pe_psum_valid_in;
    logic signed [DATA_WIDTH_IN-1:0]     pe_input_in;

    // DUT 输出 (Outputs)
    logic signed [DATA_WIDTH_IN-1:0]     pe_weight_out;
    logic [INDEX_WIDTH-1:0]              pe_index_out;
    logic signed [DATA_WIDTH_ACCUM-1:0]  pe_psum_out;
    logic                                pe_psum_valid_out;
    logic                                pe_accept_w_out;
    logic signed [DATA_WIDTH_IN-1:0]     pe_input_out;
    logic                                pe_valid_out;
    logic                                pe_switch_out;


    // --- DUT 实例化 ---
    pe #(
        .ROW_ID               (ROW_ID),
        .SYSTOLIC_ARRAY_WIDTH (SYSTOLIC_ARRAY_WIDTH),
        .DATA_WIDTH_IN        (DATA_WIDTH_IN),
        .DATA_WIDTH_ACCUM     (DATA_WIDTH_ACCUM)
    ) uut (
        .clk                (clk),
        .rst                (rst),
        .pe_valid_in        (pe_valid_in),
        .pe_switch_in       (pe_switch_in),
        .pe_enabled         (pe_enabled),
        .pe_accept_w_in     (pe_accept_w_in),
        .pe_weight_in       (pe_weight_in),
        .pe_index_in        (pe_index_in),
        .pe_psum_in         (pe_psum_in),
        .pe_psum_valid_in   (pe_psum_valid_in),
        .pe_input_in        (pe_input_in),
        .pe_weight_out      (pe_weight_out),
        .pe_index_out       (pe_index_out),
        .pe_psum_out        (pe_psum_out),
        .pe_psum_valid_out  (pe_psum_valid_out),
        .pe_accept_w_out    (pe_accept_w_out),
        .pe_input_out       (pe_input_out),
        .pe_valid_out       (pe_valid_out),
        .pe_switch_out      (pe_switch_out)
    );


    // --- 1. 时钟生成 ---
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    // --- 辅助任务 ---
    
    // 等待指定数量的时钟周期
    task wait_clk(input int cycles = 1);
        repeat (cycles) @(posedge clk);
    endtask

    // 将所有输入重置为“空闲”状态 (0)
    task reset_inputs();
        @(negedge clk); // 在时钟下降沿驱动，以避免与 DUT 竞争
        pe_valid_in     <= 1'b0;
        pe_switch_in    <= 1'b0;
        pe_enabled      <= 1'b0;
        pe_accept_w_in  <= 1'b0;
        pe_weight_in    <= '0;
        pe_index_in     <= '0;
        pe_psum_in      <= '0;
        pe_psum_valid_in <= 1'b0;
        pe_input_in     <= '0;
    endtask


    // --- 2. 复位、激励与波形Dump ---
    initial begin
        // --- (VCD) 波形 Dump 设置 ---
        $dumpfile("tb_pe.vcd");
        $dumpvars(0, tb_pe); 

        // --- Test 1.1: 复位阶段 ---
        $display("T=%0t: [TB] Test 1.1: Applying Reset...", $time);
        rst = 1'b1;
        reset_inputs();
        
        wait_clk(2);
        
        @(negedge clk);
        rst = 1'b0;
        $display("T=%0t: [TB] Releasing Reset.", $time);
        
        wait_clk(1);

        // --- Test 1.2: 'pe_enabled = 0' (Psum 直通测试) ---
        $display("T=%0t: [TB] Test 1.2: Psum Passthrough (pe_enabled=0)", $time);
        reset_inputs();
        
        @(posedge clk);
        pe_psum_in       <= 32'd1234;
        pe_psum_valid_in <= 1'b1;
        
        @(posedge clk);
        pe_psum_in       <= 32'd5678;
        pe_psum_valid_in <= 1'b1;
        // 检查: T=30ns, psum_out 应为 1234, psum_valid_out 应为 1
        
        @(posedge clk);
        reset_inputs();
        // 检查: T=40ns, psum_out 应为 5678, psum_valid_out 应为 1
        
        wait_clk(2);

        // --- Test 3.2: 'Eat' (加载权重 'A' = 10) ---
        $display("T=%0t: [TB] Test 3.2: Loading Weight 'A' (8'd10) via 'Eat'", $time);
        reset_inputs();
        pe_enabled <= 1'b1;
        
        @(posedge clk);
        pe_accept_w_in <= 1'b1;
        pe_index_in    <= ROW_ID; // 匹配 (0)
        pe_weight_in   <= 8'd10;
        // 检查: 下一拍, pe_accept_w_out=0, weight_reg_inactive=10

        // --- 切换权重 'A' 到 Active ---
        $display("T=%0t: [TB] Switching Weight 'A' to active", $time);
        @(posedge clk);
        reset_inputs();
        pe_enabled   <= 1'b1;
        pe_switch_in <= 1'b1;
        // 检查: 下一拍, weight_reg_active=10
        
        @(posedge clk);
        reset_inputs();
        pe_enabled <= 1'b1;
        
        // --- Test 2.1: 单次 MAC 计算 ---
        $display("T=%0t: [TB] Test 2.1: Single MAC (5 * 10 + 100 = 150)", $time);
        @(posedge clk);
        pe_valid_in      <= 1'b1;
        pe_input_in      <= 8'd5;
        pe_psum_in       <= 32'd100;
        pe_psum_valid_in <= 1'b1;
        // 检查: 下一拍, psum_out=150, psum_valid_out=1
        
        @(posedge clk);
        reset_inputs();
        pe_enabled <= 1'b1;
        
        wait_clk(2);

        // --- Test 3.1 & 3.3: 'Propagate' 和 'Stop' ---
        $display("T=%0t: [TB] Test 3.1: Propagate (Index mismatch)", $time);
        @(posedge clk);
        pe_accept_w_in <= 1'b1;
        pe_index_in    <= ROW_ID + 1; // 不匹配 (1)
        pe_weight_in   <= 8'hAA;
        // 检查: 下一拍, pe_accept_w_out=1, pe_weight_out=0xAA
        
        $display("T=%0t: [TB] Test 3.3: Stop (accept_w=0)", $time);
        @(posedge clk);
        reset_inputs();
        pe_enabled <= 1'b1;
        // 检查: 下一拍, pe_accept_w_out=0
        
        wait_clk(2);

        // --- Test 4.1: 双缓冲 (加载 'B', 边计算边切换) ---
        $display("T=%0t: [TB] Test 4.1: Double Buffering Test", $time);
        
        // 1. 加载 8'd20 (权重 'B') 到 inactive 寄存器
        $display("T=%0t: [TB]   ... Loading Weight 'B' (8'd20)", $time);
        @(posedge clk);
        pe_accept_w_in <= 1'b1;
        pe_index_in    <= ROW_ID; // 匹配 (0)
        pe_weight_in   <= 8'd20;
        
        @(posedge clk);
        reset_inputs();
        pe_enabled <= 1'b1;
        // 状态: active=10, inactive=20
        
        // 2. 使用 active=10 计算，并同时切换
        $display("T=%0t: [TB]   ... Compute (2*10) AND Switch simultaneously", $time);
        @(posedge clk);
        pe_valid_in      <= 1'b1;
        pe_input_in      <= 8'd2;    // B = 2
        pe_psum_in       <= 32'd0;
        pe_psum_valid_in <= 1'b1;
        pe_switch_in     <= 1'b1;    // 切换 active 和 inactive
        // 检查: T=160, psum_out=(2*10)=20. 
        //       DUT 内部 active 更新为 20.
        
        // 3. 使用新的 active=20 计算
        $display("T=%0t: [TB]   ... Compute (3*20) using new weight 'B'", $time);
        @(posedge clk);
        pe_valid_in      <= 1'b1;
        pe_input_in      <= 8'd3;    // B = 3
        pe_psum_in       <= 32'd0;
        pe_psum_valid_in <= 1'b1;
        pe_switch_in     <= 1'b0;    // 停止切换
        // 检查: T=170, psum_out=(3*20)=60.
        
        @(posedge clk);
        reset_inputs();
        
        wait_clk(5);

        // --- 仿真结束 ---
        $display("T=%0t: [TB] All tests complete.", $time);
        $finish; // 结束仿真
    end

    // --- 3. 信号监控 (可选) ---
    initial begin
        @(negedge rst); // 等待复位结束
        $monitor(
            "T=%0t [CLK=%b RST=%b] ENA=%b | (W_IN) Vld=%b B_in=%d | (N_IN) AccW=%b A_in=%d Idx=%d Psum_in=%d Psum_vld=%b | (E_OUT) Vld=%b B_out=%d | (S_OUT) AccW=%b Psum_out=%d Psum_vld=%b",
            $time, clk, rst, pe_enabled,
            pe_valid_in, pe_input_in,
            pe_accept_w_in, pe_weight_in, pe_index_in, pe_psum_in, pe_psum_valid_in,
            pe_valid_out, pe_input_out,
            pe_accept_w_out, pe_psum_out, pe_psum_valid_out
        );
    end

endmodule
`default_nettype wire // 恢复默认值
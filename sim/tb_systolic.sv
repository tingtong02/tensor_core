`timescale 1ns/1ps

module testbench;

    // ... (参数, 信号, 实例化, 时钟/复位 ... 都保持不变) ...
    // --- 1. Testbench 参数 ---
    localparam int W                    = 16;  // SYSTOLIC_ARRAY_WIDTH
    localparam int DATA_WIDTH_IN        = 8;
    localparam int DATA_WIDTH_ACCUM     = 32;
    localparam int CLK_PERIOD_NS        = 10;  // 10ns = 100MHz

    // --- 2. 信号声明 ---
    logic                                clk;
    logic                                rst;
    logic signed [DATA_WIDTH_IN-1:0]     sys_data_in [W];
    logic                                sys_valid_in [W];
    logic                                sys_switch_in [W];
    logic signed [DATA_WIDTH_IN-1:0]     sys_weight_in [W];
    logic [$clog2(W)-1:0]                sys_index_in [W];
    logic                                sys_accept_w_in [W];
    logic [$clog2(W+1)-1:0]              ub_rd_col_size_in;
    logic                                ub_rd_col_size_valid_in;
    logic signed [DATA_WIDTH_ACCUM-1:0]   sys_data_out [W];
    logic                                sys_valid_out [W];

    // --- 3. 实例化 DUT ---
    systolic #(
        .SYSTOLIC_ARRAY_WIDTH(W),
        .DATA_WIDTH_IN(DATA_WIDTH_IN),
        .DATA_WIDTH_ACCUM(DATA_WIDTH_ACCUM)
    ) dut (.*); // 仍然可以使用 ._，iverilog 在这里没问题

    // --- 4. 时钟和复位 ---
    initial clk = 1'b0;
    always #(CLK_PERIOD_NS / 2) clk = ~clk; 

    task reset_dut;
        rst = 1'b1;
        for (int i = 0; i < W; i++) begin
            sys_data_in[i] = '0;
            sys_valid_in[i] = 1'b0;
            sys_switch_in[i] = 1'b0;
            sys_weight_in[i] = '0;
            sys_index_in[i] = '0;
            sys_accept_w_in[i] = 1'b0;
        end
        ub_rd_col_size_in = '0;
        ub_rd_col_size_valid_in = 1'b0;
        repeat(2) @(posedge clk);
        rst = 1'b0;
        $display("[%0t ns] DUT Reset Complete.", $time);
    endtask

    // --- 5. 测试变量 ---
    byte A_matrix[2][3];
    byte B_matrix[3][2];
    int  E_expected[2][2];
    int A_COLS = 3;
    int B_COLS = 2;
    int A_ROWS = 2;
    int B_ROWS = 3;
    int psum_fall_delay;
    int result_check_time;

    // --- 6. 主测试序列 ---
    initial begin
        
        // ... (数组初始化保持不变) ...
        A_matrix[0][0] = 1; A_matrix[0][1] = 2; A_matrix[0][2] = 3;
        A_matrix[1][0] = 4; A_matrix[1][1] = 5; A_matrix[1][2] = 6;
        B_matrix[0][0] = 10; B_matrix[0][1] = 20;
        B_matrix[1][0] = 30; B_matrix[1][1] = 40;
        B_matrix[2][0] = 50; B_matrix[2][1] = 60;
        E_expected[0][0] = 220; E_expected[0][1] = 280;
        E_expected[1][0] = 490; E_expected[1][1] = 640;

        psum_fall_delay = W - B_ROWS;

        reset_dut();
        
        // ... (Phase A 和 Phase B 保持不变) ...
        $display("[%0t ns] --- Phase A: Loading Weights A(2x3) ---", $time);
        ub_rd_col_size_in = A_ROWS;
        ub_rd_col_size_valid_in = 1'b1;
        #1; @(posedge clk);
        ub_rd_col_size_valid_in = 1'b0;
        for (int i = A_COLS - 1; i >= 0; i--) begin
            sys_accept_w_in[0] = 1'b1; sys_index_in[0] = i; sys_weight_in[0] = A_matrix[0][i];
            sys_accept_w_in[1] = 1'b1; sys_index_in[1] = i; sys_weight_in[1] = A_matrix[1][i];
            #1; @(posedge clk);
        end
        sys_accept_w_in[0] = 1'b0; sys_accept_w_in[1] = 1'b0;
        $display("[%0t ns] A-Flow: Weight Load Complete.", $time);
        repeat(5) @(posedge clk);

        $display("[%0t ns] --- Phase B: Compute B(3x2) ---", $time);
        $display("[%0t ns] B-Flow: Sending Bubble (switch=1, valid=0)", $time);
        for (int i = 0; i < B_ROWS; i++) begin
            sys_switch_in[i] = 1'b1; sys_valid_in[i] = 1'b0;
        end
        #1; @(posedge clk);
        
        $display("[%0t ns] B-Flow: Sending B Column k=0", $time);
        for (int i = 0; i < B_ROWS; i++) begin
            sys_switch_in[i] = 1'b0; sys_valid_in[i]  = 1'b1; sys_data_in[i] = B_matrix[i][0];
        end
        #1; @(posedge clk);
        
        $display("[%0t ns] B-Flow: Sending B Column k=1", $time);
        for (int i = 0; i < B_ROWS; i++) begin
            sys_valid_in[i] = 1'b1; sys_data_in[i]  = B_matrix[i][1];
        end
        result_check_time = $time + (psum_fall_delay * CLK_PERIOD_NS);
        $display("[%0t ns] B-Flow: Expecting k=0 result at t=%0t", $time, result_check_time);
        #1; @(posedge clk);

        $display("[%0t ns] B-Flow: Stopping B-Flow (valid=0)", $time);
        for (int i = 0; i < B_ROWS; i++) begin
            sys_valid_in[i] = 1'b0;
        end

        // --- 5d. 阶段 C: 检查结果 (已修复) ---
        
        repeat(psum_fall_delay) @(posedge clk);
        
        $display("[%0t ns] --- Phase C: Checking Results ---", $time);
        
        // --- 关键修复：使用 $isunknown 检查 ---
        $display("[%0t ns] Checking k=0: E[0][0]=%0d, E[1][0]=%0d", 
                 sys_data_out[0], sys_data_out[1]);
        
        // 检查 k=0
        if ($isunknown(sys_data_out[0]) || sys_data_out[0] != E_expected[0][0]) begin
            $display("FATAL ERROR: E[0][0] incorrect. Expected: %0d, Got: %0d", 
                     E_expected[0][0], sys_data_out[0]);
            $finish;
        end
        if ($isunknown(sys_data_out[1]) || sys_data_out[1] != E_expected[1][0]) begin
            $display("FATAL ERROR: E[1][0] incorrect. Expected: %0d, Got: %0d", 
                     E_expected[1][0], sys_data_out[1]);
            $finish;
        end
        
        #1; @(posedge clk);
        $display("[%0t ns] Checking k=1: E[0][1]=%0d, E[1][1]=%0d", 
                 sys_data_out[0], sys_data_out[1]);
        
        // 检查 k=1
        if ($isunknown(sys_data_out[0]) || sys_data_out[0] != E_expected[0][1]) begin
            $display("FATAL ERROR: E[0][1] incorrect. Expected: %0d, Got: %0d", 
                     E_expected[0][1], sys_data_out[0]);
            $finish;
        end
        if ($isunknown(sys_data_out[1]) || sys_data_out[1] != E_expected[1][1]) begin
            $display("FATAL ERROR: E[1][1] incorrect. Expected: %0d, Got: %0d", 
                     E_expected[1][1], sys_data_out[1]);
            $finish;
        end

        $display("[%0t ns] --- All Tests Passed! ---", $time);
        $finish;
    end
    
    // --- 6. VCD 波形转储 (用于调试) ---
    initial begin
        $dumpfile("systolic_test.vcd");
        $dumpvars(0, testbench);
    end

endmodule
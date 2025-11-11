`timescale 1ns/1ps
`default_nettype none

module tb_pe;

    // --- Testbench Parameters ---
    localparam int TB_ROW_ID               = 5; 
    localparam int TB_SYSTOLIC_ARRAY_WIDTH = 16;
    localparam int TB_DATA_WIDTH_IN        = 8;
    localparam int TB_DATA_WIDTH_ACCUM     = 32;
    localparam int TB_INDEX_WIDTH          = $clog2(TB_SYSTOLIC_ARRAY_WIDTH);

    // --- Clock and Reset ---
    logic clk;
    logic rst;

    // --- DUT Inputs (Driven by Testbench) ---
    logic pe_valid_in;
    logic pe_switch_in;
    logic pe_enabled;
    logic pe_accept_w_in;
    logic signed [TB_DATA_WIDTH_IN-1:0]     pe_weight_in;
    logic [TB_INDEX_WIDTH-1:0]              pe_index_in;
    logic signed [TB_DATA_WIDTH_ACCUM-1:0]  pe_psum_in;
    logic signed [TB_DATA_WIDTH_IN-1:0]     pe_input_in;

    // --- DUT Outputs (Monitored by Testbench) ---
    wire signed [TB_DATA_WIDTH_IN-1:0]     pe_weight_out;
    wire [TB_INDEX_WIDTH-1:0]              pe_index_out;
    wire signed [TB_DATA_WIDTH_ACCUM-1:0]  pe_psum_out;
    wire                                   pe_accept_w_out;
    wire signed [TB_DATA_WIDTH_IN-1:0]     pe_input_out;
    wire                                   pe_valid_out;
    wire                                   pe_switch_out;

    // --- DUT Instantiation ---
    pe #(
        .ROW_ID               (TB_ROW_ID),
        .SYSTOLIC_ARRAY_WIDTH (TB_SYSTOLIC_ARRAY_WIDTH),
        .DATA_WIDTH_IN        (TB_DATA_WIDTH_IN),
        .DATA_WIDTH_ACCUM     (TB_DATA_WIDTH_ACCUM)
    ) dut (
        .clk                (clk),
        .rst                (rst),
        .pe_valid_in        (pe_valid_in),
        .pe_switch_in       (pe_switch_in),
        .pe_enabled         (pe_enabled),
        .pe_accept_w_in     (pe_accept_w_in),
        .pe_weight_in       (pe_weight_in),
        .pe_index_in        (pe_index_in),
        .pe_psum_in         (pe_psum_in),
        .pe_input_in        (pe_input_in),
        .pe_weight_out      (pe_weight_out),
        .pe_index_out       (pe_index_out),
        .pe_psum_out        (pe_psum_out),
        .pe_accept_w_out    (pe_accept_w_out),
        .pe_input_out       (pe_input_out),
        .pe_valid_out       (pe_valid_out),
        .pe_switch_out      (pe_switch_out)
    );

    // --- Clock Generation ---
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100MHz Clock
    end

    // --- Waveform Dump ---
    initial begin
        $dumpfile("tb_pe.vcd");
        $dumpvars(0, tb_pe);
    end

    // --- Main Test Sequence ---
    initial begin
        $display("--- Testbench Started ---");
        
        // --- 1. Reset Test ---
        $display("--- 1. Reset Test ---");
        rst = 1;
        // *** FIX: Drive all inputs to 0 during reset, not 'x' ***
        pe_enabled = 0;
        pe_valid_in = 0;
        pe_switch_in = 0;
        pe_accept_w_in = 0;
        pe_weight_in = '0;  // Was 'x'
        pe_index_in = '0;   // Was 'x'
        pe_psum_in = '0;    // Was 'x'
        pe_input_in = '0;   // Was 'x'
        
        @(posedge clk); #1ps;
        @(posedge clk); #1ps;
        rst = 0;
        $display("Reset released.");
        @(posedge clk); #1ps;

        // This should now pass, as pe_psum_in was '0'
        assert (pe_psum_out == 0) else $error("psum_out mismatch after reset");

        // --- 2. PE Disabled (pe_enabled = 0) ---
        $display("--- 2. PE Disabled Test (Psum should pass through) ---");
        pe_enabled = 0;
        pe_psum_in = 12345;
        pe_input_in = 10;
        pe_valid_in = 1;
        pe_weight_in = 20;
        pe_accept_w_in = 1;
        pe_index_in = TB_ROW_ID;

        @(posedge clk); #1ps;
        assert (pe_psum_out == 12345) else $error("Disabled PE did not pass through psum");
        assert (pe_input_out == 0) else $error("Disabled PE did not zero input_out");
        assert (pe_valid_out == 0) else $error("Disabled PE did not zero valid_out");
        assert (pe_weight_out == 0) else $error("Disabled PE did not zero weight_out");
        assert (pe_accept_w_out == 0) else $error("Disabled PE did not zero accept_w_out");

        // --- 3. Weight Loading (Signal-Eating Logic) ---
        $display("--- 3. Weight Loading Test ---");
        pe_enabled = 1;

        // 3a. Index Mismatch (Should pass through)
        $display("  3a. Index Mismatch (ROW_ID=%d, index=%d)", TB_ROW_ID, TB_ROW_ID + 1);
        pe_accept_w_in = 1;
        pe_index_in = TB_ROW_ID + 1; // Mismatch
        pe_weight_in = 8'hAA;
        @(posedge clk); #1ps;
        assert (pe_accept_w_out == 1) else $error("Index mismatch: accept_w was not passed down");
        assert (pe_weight_out == 8'hAA) else $error("Index mismatch: weight_out was not passed down");

        // 3b. Index Match (Should "eat" the signal)
        $display("  3b. Index Match (ROW_ID=%d, index=%d)", TB_ROW_ID, TB_ROW_ID);
        pe_accept_w_in = 1;
        pe_index_in = TB_ROW_ID; // Match
        pe_weight_in = 8'd10; // Load weight 10 into inactive_reg
        @(posedge clk); #1ps;
        assert (pe_accept_w_out == 0) else $error("Index match: accept_w was not eaten");
        
        // 3c. Stop loading
        pe_accept_w_in = 0;
        @(posedge clk); #1ps;

        // --- 4. MAC Function Test (using active_reg = 0) ---
        $display("--- 4. MAC Function Test (active_weight = 0) ---");
        // At this point: active_reg = 0, inactive_reg = 10
        
        // 4a. Psum Pass-through (pe_valid_in = 0)
        $display("  4a. Psum Pass-through (valid=0)");
        pe_valid_in = 0;
        pe_psum_in = 500;
        pe_input_in = 5; // B=5
        @(posedge clk); #1ps;
        assert (pe_psum_out == 500) else $error("Psum pass-through failed");
        assert (pe_valid_out == 0) else $error("valid_out is incorrect");

        // 4b. MAC Calculation (pe_valid_in = 1)
        // Expected: (B * A) + Psum = (5 * 0) + 500 = 500
        $display("  4b. MAC Calculation (valid=1, A=0)");
        pe_valid_in = 1;
        pe_psum_in = 500;
        pe_input_in = 5; // B=5
        @(posedge clk); #1ps;
        // pe_psum_out = (5 * 0) + 500 = 500
        assert (pe_psum_out == 500) else $error("MAC calculation (A=0) failed");
        assert (pe_valid_out == 1) else $error("valid_out is incorrect");
        assert (pe_input_out == 5) else $error("input_out is incorrect");

        // --- 5. Weight Switch ---
        $display("--- 5. Weight Switch Test ---");
        pe_switch_in = 1;
        @(posedge clk); #1ps;
        // Internal active_reg now becomes 10
        pe_switch_in = 0;
        assert (pe_switch_out == 1) else $error("switch_out is incorrect");
        @(posedge clk); #1ps;
        assert (pe_switch_out == 0) else $error("switch_out delay is incorrect");

        // --- 6. MAC Function Test (using active_reg = 10) ---
        $display("--- 6. MAC Function Test (active_weight = 10) ---");
        
        // 6a. MAC Calculation
        // Expected: (B * A) + Psum = (7 * 10) + 100 = 170
        $display("  6a. MAC Calculation (A=10)");
        pe_valid_in = 1;
        pe_input_in = 7;  // B=7
        pe_psum_in = 100; // Psum=100
        @(posedge clk); #1ps;
        // pe_psum_out = (7 * 10) + 100 = 170
        assert (pe_psum_out == 170) else $error("MAC calculation (A=10) failed");

        // 6b. Continuous MAC Calculation (Signed Test)
        // Expected: (B * A) + Psum = (-2 * 10) + 170 = -20 + 170 = 150
        $display("  6b. Continuous MAC Calculation (Signed)");
        pe_valid_in = 1;
        pe_input_in = -2; // B=-2
        pe_psum_in = 170; // Psum=170 (from previous cycle)
        @(posedge clk); #1ps;
        // pe_psum_out = (-2 * 10) + 170 = 150
        assert (pe_psum_out == 150) else $error("Signed MAC calculation failed");
        
        pe_valid_in = 0;
        @(posedge clk); #1ps;

        // --- 7. Final Reset Test ---
        $display("--- 7. Final Reset Test ---");
        rst = 1;
        // *** FIX: Drive all inputs to 0 during reset, not 'x' ***
        pe_enabled = 0;
        pe_valid_in = 0;
        pe_switch_in = 0;
        pe_accept_w_in = 0;
        pe_weight_in = '0;
        pe_index_in = '0;
        pe_psum_in = '0;
        pe_input_in = '0;
        @(posedge clk); #1ps;
        @(posedge clk); #1ps;
        rst = 0;
        @(posedge clk); #1ps;
        
        // Check if internal weights were reset
        $display("  7a. Check if weights were reset (A=0)");
        pe_enabled = 1;
        pe_valid_in = 1;
        pe_input_in = 10; // B=10
        pe_psum_in = 1000; // Psum=1000
        @(posedge clk); #1ps;
        // Expected: (B * A) + Psum = (10 * 0) + 1000 = 1000
        assert (pe_psum_out == 1000) else $error("active_weight was not cleared after reset");

        $display("--- All Tests Passed ---");
        $finish;
    end

endmodule
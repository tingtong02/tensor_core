`timescale 1ns/1ps

module testbench;

    // --- 1. Testbench Parameters ---
    localparam int P_ROW_ID               = 5;
    localparam int P_SYSTOLIC_ARRAY_WIDTH = 16;
    localparam int P_DATA_WIDTH_IN        = 8;
    localparam int P_DATA_WIDTH_ACCUM     = 32;
    localparam int CLK_PERIOD_NS          = 10;  // 10ns = 100MHz

    // --- 2. Signal Declarations ---
    logic                                clk;
    logic                                rst;
    logic                                pe_enabled;
    logic                                pe_accept_w_in;
    logic                                pe_valid_in;
    logic                                pe_switch_in;
    logic signed [P_DATA_WIDTH_IN-1:0]     pe_weight_in;
    logic [$clog2(P_SYSTOLIC_ARRAY_WIDTH)-1:0] pe_index_in;
    logic signed [P_DATA_WIDTH_ACCUM-1:0]   pe_psum_in;
    logic signed [P_DATA_WIDTH_IN-1:0]     pe_input_in;
    // (DUT Outputs)
    logic signed [P_DATA_WIDTH_IN-1:0]     pe_weight_out;
    logic [$clog2(P_SYSTOLIC_ARRAY_WIDTH)-1:0] pe_index_out;
    logic signed [P_DATA_WIDTH_ACCUM-1:0]   pe_psum_out;
    logic                                pe_accept_w_out;
    logic signed [P_DATA_WIDTH_IN-1:0]     pe_input_out;
    logic                                pe_valid_out;
    logic                                pe_switch_out;

    // --- 3. Test Variables ---
    byte  test_A_weight = 10;
    byte  test_B_input_0 = 2;
    byte  test_B_input_1 = 3;
    int   test_psum_in_0 = 100;
    int   test_psum_in_1 = 200;
    int   expected_psum_out_0;
    int   expected_psum_out_1;

    // --- 4. Instantiate DUT ---
    pe #(
        .ROW_ID(P_ROW_ID),
        .SYSTOLIC_ARRAY_WIDTH(P_SYSTOLIC_ARRAY_WIDTH),
        .DATA_WIDTH_IN(P_DATA_WIDTH_IN),
        .DATA_WIDTH_ACCUM(P_DATA_WIDTH_ACCUM)
    ) dut (
        .clk(clk),
        .rst(rst),
        .pe_enabled(pe_enabled),
        .pe_accept_w_in(pe_accept_w_in),
        .pe_weight_in(pe_weight_in),
        .pe_index_in(pe_index_in),
        .pe_psum_in(pe_psum_in),
        .pe_valid_in(pe_valid_in),
        .pe_switch_in(pe_switch_in),
        .pe_input_in(pe_input_in),
        .pe_weight_out(pe_weight_out),
        .pe_index_out(pe_index_out),
        .pe_psum_out(pe_psum_out),
        .pe_accept_w_out(pe_accept_w_out),
        .pe_input_out(pe_input_out),
        .pe_valid_out(pe_valid_out),
        .pe_switch_out(pe_switch_out)
    );

    // --- 5. Clock and Reset ---
    initial clk = 1'b0;
    // *** FIX 1: Use hard-coded integer delay for clock ***
    always #(CLK_PERIOD_NS / 2) clk = ~clk; // Now #5

    task reset_dut;
        rst = 1'b1;
        pe_enabled = 1'b0;
        pe_accept_w_in = 1'b0;
        pe_valid_in = 1'b0;
        pe_switch_in = 1'b0;
        pe_weight_in = '0;
        pe_index_in = '0;
        pe_psum_in = '0;
        pe_input_in = '0;
        repeat(2) @(posedge clk);
        rst = 1'b0;
        pe_enabled = 1'b1;
        $display("[%0t ns] DUT Reset Complete. PE is Enabled.", $time);
    endtask

    // --- 6. Main Test Sequence ---
    initial begin
        
        expected_psum_out_0 = (test_B_input_0 * 0) + test_psum_in_0; // 100
        expected_psum_out_1 = (test_B_input_1 * test_A_weight) + test_psum_in_1; // 230

        reset_dut();
        
        $display("[%0t ns] --- Phase A: Weight Load (A-Flow) ---", $time);
        $display("[%0t ns] Target: PE[ID=%0d] must capture index=%0d with value (%0d)", 
                 $time, P_ROW_ID, P_ROW_ID, test_A_weight);

        pe_accept_w_in = 1'b1;
        for (int i = 15; i > P_ROW_ID; i--) begin
            pe_weight_in = 8'hFF;
            pe_index_in = i;
            #1; // *** FIX 2: Add 1ps delay to fix race condition ***
            @(posedge clk);
            if (pe_accept_w_out != 1'b1) begin
                $display("FATAL ERROR: A-Flow Fail: pe_accept_w_out should be 1 (index %0d)", i);
                $finish;
            end
        end

        $display("[%0t ns] A-Flow: Sending matching index %0d...", $time, P_ROW_ID);
        pe_weight_in = test_A_weight;
        pe_index_in = P_ROW_ID;
        #1; // *** FIX 2 ***
        @(posedge clk);
        if (pe_accept_w_out != 1'b0) begin
            $display("FATAL ERROR: A-Flow Fail: pe_accept_w_out should be 0 (index %0d)", P_ROW_ID);
            $finish;
        end
        
        for (int i = P_ROW_ID - 1; i >= 0; i--) begin
            pe_weight_in = 8'hFF;
            pe_index_in = i;
            #1; // *** FIX 2 ***
            @(posedge clk);
            if (pe_accept_w_out != 1'b1) begin
                $display("FATAL ERROR: A-Flow Fail: pe_accept_w_out should be 1 (index %0d)", i);
                $finish;
            end
        end

        pe_accept_w_in = 1'b0;
        pe_weight_in = '0;
        pe_index_in = '0;
        #1; // *** FIX 2 ***
        @(posedge clk);
        if (pe_accept_w_out != 1'b0) begin
            $display("FATAL ERROR: A-Flow Fail: pe_accept_w_out (stream off) should be 0");
            $finish;
        end
        
        $display("[%0t ns] A-Flow: Phase A (Weight Load) Verified!", $time);
        @(posedge clk); // Wait one cycle
        
        $display("[%0t ns] --- Phase B: Compute (B-Flow) ---", $time);

        $display("[%0t ns] B-Flow: Sending B[0] (%0d) + psum_in (%0d) + switch=1", 
                 $time, test_B_input_0, test_psum_in_0);
        pe_valid_in  = 1'b1;
        pe_switch_in = 1'b1; 
        pe_input_in  = test_B_input_0;
        pe_psum_in   = test_psum_in_0;
        #1; // *** FIX 2 ***
        @(posedge clk);
        
        $display("[%0t ns] B-Flow: Sending B[1] (%0d) + psum_in (%0d) + switch=0", 
                 $time, test_B_input_1, test_psum_in_1);
        
        if (pe_psum_out != expected_psum_out_0) begin
            $display("FATAL ERROR: B-Flow Fail: Cycle 0 Psum incorrect. Expected: %0d, Got: %0d", 
                     expected_psum_out_0, pe_psum_out);
            $finish;
        end
        $display("[%0t ns] B-Flow: Cycle 0 Results Verified (Psum=%0d)", $time, pe_psum_out);

        pe_valid_in  = 1'b1;
        pe_switch_in = 1'b0; 
        pe_input_in  = test_B_input_1;
        pe_psum_in   = test_psum_in_1;
        #1; // *** FIX 2 ***
        @(posedge clk);

        $display("[%0t ns] B-Flow: Stopping B-flow (valid=0)", $time);

        if (pe_psum_out != expected_psum_out_1) begin
            $display("FATAL ERROR: B-Flow Fail: Cycle 1 Psum incorrect. Expected: %0d, Got: %0d", 
                     expected_psum_out_1, pe_psum_out);
            $finish;
        end
        $display("[%0t ns] B-Flow: Cycle 1 Results Verified (Psum=%0d)", $time, pe_psum_out);
        
        pe_valid_in  = 1'b0;
        pe_switch_in = 1'b0;
        pe_input_in  = '0;
        pe_psum_in   = '0;
        #1; // *** FIX 2 ***
        @(posedge clk);
        
        $display("[%0t ns] B-Flow: Checking pipeline flush", $time);
        
        if (pe_psum_out != 0) begin
            $display("FATAL ERROR: B-Flow Fail: Pipeline flush failed. Psum Expected: 0, Got: %0d", pe_psum_out);
            $finish;
        end
        $display("[%0t ns] B-Flow: Pipeline flush verified!", $time);
        
        @(posedge clk);
        $display("[%0t ns] --- All Tests Passed! ---", $time);
        $finish;
    end

endmodule
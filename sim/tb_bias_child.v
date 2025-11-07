`timescale 1ns/1ps
`default_nettype none

module tb_bias_child;

    // --- Simulation Control ---
    localparam CLK_PERIOD = 10; // 10ns clock period

    // --- DUT Interface Signals ---
    // Inputs (reg)
    reg clk;
    reg rst;
    reg signed [31:0] bias_scalar_in;
    reg signed [31:0] bias_sys_data_in;
    reg               bias_sys_valid_in;

    // Outputs (wire)
    wire signed [31:0] bias_z_data_out;
    wire               bias_Z_valid_out;

    // --- Instantiate DUT (Device Under Test) ---
    bias_child dut (
        .clk(clk),
        .rst(rst),
        .bias_scalar_in(bias_scalar_in),
        .bias_sys_data_in(bias_sys_data_in),
        .bias_sys_valid_in(bias_sys_valid_in),
        .bias_z_data_out(bias_z_data_out),
        .bias_Z_valid_out(bias_Z_valid_out)
    );

    // --- 1. Clock Generation ---
    always begin
        clk = 1'b0;
        #(CLK_PERIOD / 2);
        clk = 1'b1;
        #(CLK_PERIOD / 2);
    end

    // --- 2. Simulation Stimulus ---
    initial begin
        // Open VCD waveform file
        $dumpfile("bias_child_waves.vcd");
        $dumpvars(0, tb_bias_child);

        $display("--- Simulation Start (bias_child) ---");

        // --- Step 0: Initialization and Reset ---
        bias_scalar_in    = 0;
        bias_sys_data_in  = 0;
        bias_sys_valid_in = 0;
        rst               = 1; // Assert reset

        $display("[%0t] 0. Module in Reset...", $time);
        @(posedge clk);
        @(posedge clk);
        
        rst = 0; // De-assert reset
        $display("[%0t] 0. Reset complete.", $time);

        // --- Step 1: Test Invalid Input ---
        // Inputs should be ignored, outputs should be 0/invalid
        bias_scalar_in    = 100;
        bias_sys_data_in  = 50;
        bias_sys_valid_in = 0;
        $display("[%0t] 1. Test: Invalid Input (Valid=0)", $time);

        @(posedge clk);
        $display("[%0t] 1. Result: Z_DataOut=%d (Expected 0), Z_ValidOut=%b (Expected 0)", 
                 $time, bias_z_data_out, bias_Z_valid_out);

        // --- Step 2: Test Valid (Positive + Positive) ---
        bias_scalar_in    = 20;
        bias_sys_data_in  = 80;
        bias_sys_valid_in = 1;
        $display("[%0t] 2. Test: Valid Data (80 + 20)", $time);

        @(posedge clk);
        // At this edge, output registers should latch the result
        $display("[%0t] 2. Result: Z_DataOut=%d (Expected 100), Z_ValidOut=%b (Expected 1)", 
                 $time, bias_z_data_out, bias_Z_valid_out);
        
        // --- Step 3: Test Valid (Positive + Negative Bias) ---
        bias_scalar_in    = -10;
        bias_sys_data_in  = 50;
        bias_sys_valid_in = 1;
        $display("[%0t] 3. Test: Valid Data (50 + (-10))", $time);

        @(posedge clk);
        $display("[%0t] 3. Result: Z_DataOut=%d (Expected 40), Z_ValidOut=%b (Expected 1)", 
                 $time, bias_z_data_out, bias_Z_valid_out);

        // --- Step 4: Test Valid (Negative Data + Positive Bias) ---
        bias_scalar_in    = 30;
        bias_sys_data_in  = -100;
        bias_sys_valid_in = 1;
        $display("[%0t] 4. Test: Valid Data (-100 + 30)", $time);

        @(posedge clk);
        $display("[%0t] 4. Result: Z_DataOut=%d (Expected -70), Z_ValidOut=%b (Expected 1)", 
                 $time, bias_z_data_out, bias_Z_valid_out);

        // --- Step 5: Test transition back to Invalid ---
        // Outputs should return to 0/invalid
        bias_scalar_in    = 99; // Garbage data
        bias_sys_data_in  = 99; // Garbage data
        bias_sys_valid_in = 0;
        $display("[%0t] 5. Test: Back to Invalid (Valid=0)", $time);

        @(posedge clk);
        $display("[%0t] 5. Result: Z_DataOut=%d (Expected 0), Z_ValidOut=%b (Expected 0)", 
                 $time, bias_z_data_out, bias_Z_valid_out);

        // --- Step 6: End simulation ---
        $display("[%0t] --- Simulation End ---", $time);
        #50;
        $finish;
    end

endmodule
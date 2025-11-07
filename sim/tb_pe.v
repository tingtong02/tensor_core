`timescale 1ns/1ps
`default_nettype none

module tb_pe;

    // --- Simulation Control ---
    localparam CLK_PERIOD = 10; // 10ns clock period

    // --- DUT Interface Signals ---
    // Inputs (reg)
    reg clk;
    reg rst;
    reg signed [31:0] pe_psum_in;
    reg signed [7:0]  pe_weight_in;
    reg               pe_accept_w_in;
    reg signed [7:0]  pe_input_in;
    reg               pe_valid_in;
    reg               pe_switch_in;
    reg               pe_enabled;

    // Outputs (wire)
    wire signed [31:0] pe_psum_out;
    wire signed [7:0]  pe_weight_out;
    wire signed [7:0]  pe_input_out;
    wire               pe_valid_out;
    wire               pe_switch_out;

    // --- Instantiate DUT (Device Under Test) ---
    pe dut (
        .clk(clk),
        .rst(rst),
        .pe_psum_in(pe_psum_in),
        .pe_weight_in(pe_weight_in),
        .pe_accept_w_in(pe_accept_w_in),
        .pe_input_in(pe_input_in),
        .pe_valid_in(pe_valid_in),
        .pe_switch_in(pe_switch_in),
        .pe_enabled(pe_enabled),
        .pe_psum_out(pe_psum_out),
        .pe_weight_out(pe_weight_out),
        .pe_input_out(pe_input_out),
        .pe_valid_out(pe_valid_out),
        .pe_switch_out(pe_switch_out)
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
        $dumpfile("pe_waves.vcd");
        $dumpvars(0, tb_pe);

        $display("--- Simulation Start ---");

        // --- Step 0: Initialization and Reset ---
        pe_psum_in     = 0;
        pe_weight_in   = 0;
        pe_accept_w_in = 0;
        pe_input_in    = 0;
        pe_valid_in    = 0;
        pe_switch_in   = 0;
        pe_enabled     = 0; // Disable
        rst            = 1; // Assert reset

        $display("[%0t] 0. Module in Reset...", $time);
        @(posedge clk);
        @(posedge clk);
        
        rst        = 0; // De-assert reset
        pe_enabled = 1; // Enable module
        $display("[%0t] 0. Reset complete. Module enabled.", $time);

        // --- Step 1: Load weight into 'inactive' register ---
        pe_weight_in   = 5;
        pe_accept_w_in = 1;
        $display("[%0t] 1. Loading weight 5 into 'inactive' register...", $time);
        
        @(posedge clk); // Wait one cycle
        pe_accept_w_in = 0; // Stop loading
        
        // --- Step 2: Switch weight, activating 'inactive' (5) to 'active' ---
        pe_switch_in = 1;
        $display("[%0t] 2. Activating weight... (Active weight will be 5 next cycle)", $time);
        
        @(posedge clk); // Wait one cycle
        pe_switch_in = 0; // Stop switching
        // After this clock edge, pe.weight_reg_active should be 5
        
        // --- Step 3: First MAC operation (Active Weight = 5) ---
        pe_input_in = 3;
        pe_psum_in  = 10;
        pe_valid_in = 1;
        $display("[%0t] 3. MAC Cycle 1: (Input=3, Weight=5, PsumIn=10)", $time);
        
        @(posedge clk); // Wait for calculation cycle
        // Expect: mac_out = (3 * 5) + 10 = 25
        // At this edge, pe_psum_out should be 25
        $display("[%0t] 3. Result: PsumOut=%d (Expected 25), InputOut=%d (Expected 3)", 
                 $time, pe_psum_out, pe_input_out);

        // --- Step 4: Second MAC operation (testing negative numbers) ---
        pe_input_in = -2; // (8'shFE)
        pe_psum_in  = 100;
        pe_valid_in = 1;
        $display("[%0t] 4. MAC Cycle 2: (Input=-2, Weight=5, PsumIn=100)", $time);

        @(posedge clk); // Wait for calculation cycle
        // Expect: mac_out = (-2 * 5) + 100 = 90
        $display("[%0t] 4. Result: PsumOut=%d (Expected 90), InputOut=%d (Expected -2)", 
                 $time, pe_psum_out, pe_input_out);

        // --- Step 5: Test pe_valid_in = 0 ---
        pe_input_in = 50; // Garbage data
        pe_psum_in  = 50; // Garbage data
        pe_valid_in = 0; // !! Invalid input !!
        $display("[%0t] 5. Invalid Cycle: (Valid=0)", $time);
        
        @(posedge clk); // Wait for cycle
        // Expect: pe_psum_out should clear to 0
        $display("[%0t] 5. Result: PsumOut=%d (Expected 0), ValidOut=%b (Expected 0)", 
                 $time, pe_psum_out, pe_valid_out);
        
        // --- Step 6: End simulation ---
        $display("[%0t] --- Simulation End ---", $time);
        #50;
        $finish;

    end

endmodule
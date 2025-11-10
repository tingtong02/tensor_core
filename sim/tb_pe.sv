`timescale 1ns/1ps
`default_nettype none

module tb_pe;

    // --- 信号 (Signals) ---
    logic clk;
    logic rst;

    // North
    logic signed [31:0] pe_psum_in;
    logic signed [ 7:0] pe_weight_in;
    logic               pe_accept_w_in;
    
    // West
    logic signed [ 7:0] pe_input_in;
    logic               pe_valid_in;
    logic               pe_switch_in;
    
    logic               pe_enabled;

    // South
    logic signed [31:0] pe_psum_out;
    logic signed [ 7:0] pe_weight_out;

    // East
    logic signed [ 7:0] pe_input_out;
    logic               pe_valid_out;
    logic               pe_switch_out;

    // --- 实例化 DUT (Instantiate DUT) ---
    pe uut (
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

    // --- 时钟 (Clock) ---
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 10ns 周期 (100MHz)
    end

    // --- 波形 (Waveform Dump for GTKWave) ---
    initial begin
        $dumpfile("pe_wave.vcd");
        $dumpvars(0, uut);
        $dumpvars(1, tb_pe); // 也 dump testbench 信号
    end

    // --- 激励 (Stimulus) ---
    initial begin
        $display("--- PE Testbench Start ---");
        
        // 1. Reset
        rst = 1;
        pe_enabled = 0;
        pe_psum_in = 'x;
        pe_weight_in = 'x;
        pe_accept_w_in = 0;
        pe_input_in = 'x;
        pe_valid_in = 0;
        pe_switch_in = 0;
        
        @(posedge clk);
        @(posedge clk);
        rst = 0;
        $display("%0t: [Test 1] Reset released. Outputs should be 0.", $time);

        // 2. Enable PE
        @(posedge clk);
        pe_enabled = 1;
        $display("%0t: [Test 2] PE Enabled.", $time);

        // 3. Load Inactive Weight
        @(posedge clk);
        pe_accept_w_in = 1;
        pe_weight_in = 5; // 加载权重 5
        $display("%0t: [Test 3] Loading inactive weight = 5. pe_weight_out should be 5.", $time);

        @(posedge clk);
        pe_accept_w_in = 0;
        pe_weight_in = 'x;
        // 此时: inactive=5, active=0

        // 4. Run MAC with Active Weight = 0
        @(posedge clk);
        pe_input_in = 10;
        pe_valid_in = 1;
        pe_psum_in = 100;
        $display("%0t: [Test 4] Sending data (10) and psum (100). Active weight is 0.", $time);
        
        @(posedge clk);
        // 预期: psum_out = (10 * 0) + 100 = 100
        $display("%0t:          Result: psum_out=%0d (Expected 100)", $time, pe_psum_out);
        $display("%0t:          Result: valid_out=%b, input_out=%0d", $time, pe_valid_out, pe_input_out);
        pe_valid_in = 0;
        pe_input_in = 'x;

        // 5. Switch Weights
        @(posedge clk);
        pe_switch_in = 1;
        $display("%0t: [Test 5] Asserting switch. Active weight should become 5.", $time);
        
        @(posedge clk);
        pe_switch_in = 0;
        // 此时: inactive=5, active=5

        // 6. Run MAC with Active Weight = 5
        @(posedge clk);
        pe_input_in = 20;
        pe_valid_in = 1;
        pe_psum_in = 7;
        $display("%0t: [Test 6] Sending data (20) and psum (7). Active weight is 5.", $time);
        
        @(posedge clk);
        // 预期: psum_out = (20 * 5) + 7 = 107
        $display("%0t:          Result: psum_out=%0d (Expected 107)", $time, pe_psum_out);
        $display("%0t:          Result: valid_out=%b, input_out=%0d", $time, pe_valid_out, pe_input_out);
        pe_valid_in = 0;
        pe_input_in = 'x;

        // 7. Test Psum Passthrough (Bubble)
        @(posedge clk);
        pe_valid_in = 0; // 'valid' 为 0, 这是一个 "气泡"
        pe_psum_in = 999; // 这是一个需要被传递的值
        $display("%0t: [Test 7] Sending bubble (valid=0) with psum_in=999.", $time);

        @(posedge clk);
        // 预期: psum_out 应该等于 psum_in (999)，而不是 0 或 mac_out
        $display("%0t:          Result: psum_out=%0d (Expected 999)", $time, pe_psum_out);
        $display("%0t:          Result: valid_out=%b", $time, pe_valid_out);
        pe_psum_in = 'x;
        
        // 8. Test Disabled
        @(posedge clk);
        pe_enabled = 0;
        $display("%0t: [Test 8] Disabling PE (pe_enabled=0).", $time);
        
        @(posedge clk);
        pe_input_in = 50;
        pe_valid_in = 1;
        pe_psum_in = 50;
        $display("%0t:          Sending data while disabled.", $time);

        @(posedge clk);
        // 预期: 所有输出都应被强制为 0
        $display("%0t:          Result: psum_out=%0d (Expected 0)", $time, pe_psum_out);
        $display("%0t:          Result: valid_out=%b (Expected 0)", $time, pe_valid_out);

        repeat(5) @(posedge clk);
        $display("--- PE Testbench End ---");
        $stop;
    end

endmodule
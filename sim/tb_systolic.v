`timescale 1ns/1ps
`default_nettype none

module tb_systolic;

    // --- Simulation Control ---
    localparam CLK_PERIOD = 10;
    
    // !!! Override WIDTH to 2 for a 2x2 array test !!!
    localparam WIDTH = 2;

    // --- DUT Interface Signals ---
    // Inputs (reg)
    reg clk;
    reg rst;
    reg signed [7:0] sys_data_in [WIDTH-1:0];
    reg              sys_start_in [WIDTH-1:0];
    reg signed [7:0] sys_weight_in [WIDTH-1:0];
    reg              sys_accept_w_in [WIDTH-1:0];
    reg              sys_switch_in;
    reg [15:0]       ub_rd_col_size_in;
    reg              ub_rd_col_size_valid_in;

    // Outputs (wire)
    wire signed [31:0] sys_data_out [WIDTH-1:0];
    wire               sys_valid_out [WIDTH-1:0];

    // --- Instantiate DUT (Device Under Test) ---
    systolic #(
        .WIDTH(WIDTH) // Override the parameter
    ) dut (
        .clk(clk),
        .rst(rst),
        .sys_data_in(sys_data_in),
        .sys_start_in(sys_start_in),
        .sys_data_out(sys_data_out),
        .sys_valid_out(sys_valid_out),
        .sys_weight_in(sys_weight_in),
        .sys_accept_w_in(sys_accept_w_in),
        .sys_switch_in(sys_switch_in),
        .ub_rd_col_size_in(ub_rd_col_size_in),
        .ub_rd_col_size_valid_in(ub_rd_col_size_valid_in)
    );

    // --- 1. Clock Generation ---
    always begin
        clk = 1'b0;
        #(CLK_PERIOD / 2);
        clk = 1'b1;
        #(CLK_PERIOD / 2);
    end

    // --- 2. Simulation Stimulus ---
    integer i;
    initial begin
        $dumpfile("systolic_waves.vcd");
        $dumpvars(0, tb_systolic);

        $display("--- Simulation Start (Systolic %dx%d) ---", WIDTH, WIDTH);

        // --- Step 0: Initialization and Reset ---
        sys_switch_in = 0;
        ub_rd_col_size_in = 0;
        ub_rd_col_size_valid_in = 0;
        for (i = 0; i < WIDTH; i = i + 1) begin
            sys_data_in[i]     = 0;
            sys_start_in[i]    = 0;
            sys_weight_in[i]   = 0;
            sys_accept_w_in[i] = 0;
        end
        rst = 1;

        $display("[%0t] 0. Module in Reset...", $time);
        @(posedge clk);
        @(posedge clk);
        
        rst = 0;
        $display("[%0t] 0. Reset complete.", $time);

        // --- Step 1: Enable PE Columns ---
        ub_rd_col_size_in = WIDTH; // Enable all 2 columns
        ub_rd_col_size_valid_in = 1;
        $display("[%0t] 1. Enabling %d PE columns...", $time, WIDTH);
        
        @(posedge clk);
        ub_rd_col_size_valid_in = 0;

        // --- Step 2: Load Weights (into inactive registers) ---
        // We must load weights for both rows
        $display("[%0t] 2. Loading weights...", $time);
        
        // Load weights for Row 0 (W[0][0]=5, W[0][1]=10)
        sys_accept_w_in[0] = 1;
        sys_accept_w_in[1] = 1;
        sys_weight_in[0]   = 5; 
        sys_weight_in[1]   = 10;
        $display("    -> Weights for Row 0: Col0=5, Col1=10");
        @(posedge clk);

        // Load weights for Row 1 (W[1][0]=3, W[1][1]=4)
        // These are fed into the top and propagate down
        sys_weight_in[0] = 3; 
        sys_weight_in[1] = 4;
        $display("    -> Weights for Row 1: Col0=3, Col1=4");
        @(posedge clk);
        
        sys_accept_w_in[0] = 0;
        sys_accept_w_in[1] = 0;
        $display("[%0t] 2. Weight loading complete.", $time);

        // --- Step 3: Switch Weights (Activate) ---
        // This takes time to propagate through the 2x2 grid
        $display("[%0t] 3. Activating weights (switch=1)...", $time);
        sys_switch_in = 1;
        
        @(posedge clk); // Switch hits PE[0][0]
        sys_switch_in = 0;
        
        @(posedge clk); // Switch hits PE[0][1] and PE[1][0]
        @(posedge clk); // Switch hits PE[1][1]
        @(posedge clk); // Extra cycle for stability
        $display("[%0t] 3. Weights should be active.", $time);
        
        // --- Step 4: Feed data pulse ---
        // We will send one piece of data: sys_data_in[0] = 2
        // We expect:
        // T0: PE[0][0] computes (2 * 5) = 10.
        // T1: PE[0][1] computes (2 * 10) = 20. (Data 2 moved right)
        //     PE[1][0] computes (0 * 3) + 10 = 10. (Psum 10 moved down)
        // T2: PE[1][1] computes (0 * 4) + 20 = 20. (Psum 20 moved down)
        //
        // Final output sys_data_out[0] (from PE[1][0]) should pulse 10 at T1.
        // Final output sys_data_out[1] (from PE[1][1]) should pulse 20 at T2.
        
        $display("[%0t] 4. Feeding data pulse: sys_data_in[0] = 2", $time);
        sys_data_in[0]  = 2;
        sys_start_in[0] = 1;
        
        @(posedge clk); // T0
        sys_data_in[0]  = 0;
        sys_start_in[0] = 0;
        $display("[%0t] 4. Data pulse sent. Watching outputs...", $time);

        @(posedge clk); // T1
        $display("[%0t] CHECK 1: ValidOut[0]=%b (Exp 1), DataOut[0]=%d (Exp 10)", 
                 $time, sys_valid_out[0], sys_data_out[0]);
        $display("[%0t] CHECK 1: ValidOut[1]=%b (Exp 0), DataOut[1]=%d (Exp 0)", 
                 $time, sys_valid_out[1], sys_data_out[1]);

        @(posedge clk); // T2
        $display("[%0t] CHECK 2: ValidOut[0]=%b (Exp 0), DataOut[0]=%d (Exp 0)", 
                 $time, sys_valid_out[0], sys_data_out[0]);
        $display("[%0t] CHECK 2: ValidOut[1]=%b (Exp 1), DataOut[1]=%d (Exp 20)", 
                 $time, sys_valid_out[1], sys_data_out[1]);

        @(posedge clk); // T3
        $display("[%0t] CHECK 3: ValidOut[0]=%b (Exp 0), DataOut[0]=%d (Exp 0)", 
                 $time, sys_valid_out[0], sys_data_out[0]);
        $display("[%0t] CHECK 3: ValidOut[1]=%b (Exp 0), DataOut[1]=%d (Exp 0)", 
                 $time, sys_valid_out[1], sys_data_out[1]);

        // --- Step 5: End simulation ---
        $display("[%0t] --- Simulation End ---", $time);
        #50;
        $finish;
    end

endmodule
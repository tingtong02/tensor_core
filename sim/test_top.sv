`timescale 1ns/1ps

module test_top;

    // 1. 参数
    parameter int SYSTOLIC_ARRAY_WIDTH = 16;
    parameter int DATA_WIDTH_IN        = 8;
    parameter int DATA_WIDTH_ACCUM     = 32;
    parameter int ADDR_WIDTH           = 10;
    
    // 2. 信号
    logic clk, rst;
    
    // Host Write Interface (Direct to Core)
    logic [ADDR_WIDTH-1:0]       host_wr_addr_in;
    logic                        host_wr_en_in;
    logic [DATA_WIDTH_ACCUM-1:0] host_wr_data_in [SYSTOLIC_ARRAY_WIDTH];

    // AXI Read Interface (From Core Output Buffer)
    logic [ADDR_WIDTH-1:0]       axim_rd_addr_in;
    logic                        axim_rd_en_in;
    logic [DATA_WIDTH_ACCUM-1:0] axim_rd_data_out [SYSTOLIC_ARRAY_WIDTH];

    // Control Unit Host Interface
    logic        cmd_valid;
    logic [63:0] cmd_data;
    logic        cmd_ready;
    logic        busy;
    logic        done_irq;

    // Interconnect Signals (Wires between CU and Core)
    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_a, ctrl_rd_addr_b, ctrl_rd_addr_c, ctrl_wr_addr_d;
    logic                  ctrl_rd_en_a, ctrl_rd_en_b, ctrl_rd_en_c;
    logic                  ctrl_a_valid, ctrl_a_switch;
    logic                  ctrl_b_accept_w;
    logic [$clog2(SYSTOLIC_ARRAY_WIDTH)-1:0] ctrl_b_weight_index;
    logic                  ctrl_c_valid;
    logic [2:0]            ctrl_vpu_mode;
    logic                  core_writeback_valid;
    logic [SYSTOLIC_ARRAY_WIDTH-1:0] ctrl_row_mask, ctrl_col_mask;

    // 3. 实例化 (Back-to-Back Connection)
    
    control_unit #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .SYSTOLIC_ARRAY_WIDTH(SYSTOLIC_ARRAY_WIDTH)
    ) u_cu (
        .clk(clk), .rst(rst),
        .cmd_valid(cmd_valid), .cmd_data(cmd_data), .cmd_ready(cmd_ready), .busy(busy), .done_irq(done_irq),
        
        .ctrl_rd_addr_a(ctrl_rd_addr_a), .ctrl_rd_en_a(ctrl_rd_en_a), .ctrl_a_valid(ctrl_a_valid), .ctrl_a_switch(ctrl_a_switch),
        .ctrl_rd_addr_b(ctrl_rd_addr_b), .ctrl_rd_en_b(ctrl_rd_en_b), .ctrl_b_accept_w(ctrl_b_accept_w), .ctrl_b_weight_index(ctrl_b_weight_index),
        .ctrl_rd_addr_c(ctrl_rd_addr_c), .ctrl_rd_en_c(ctrl_rd_en_c), .ctrl_c_valid(ctrl_c_valid), .ctrl_vpu_mode(ctrl_vpu_mode),
        
        .core_writeback_valid(core_writeback_valid), .ctrl_wr_addr_d(ctrl_wr_addr_d),
        .ctrl_row_mask(ctrl_row_mask), .ctrl_col_mask(ctrl_col_mask)
    );

    tpu_core #(
        .SYSTOLIC_ARRAY_WIDTH(SYSTOLIC_ARRAY_WIDTH),
        .DATA_WIDTH_IN(DATA_WIDTH_IN),
        .DATA_WIDTH_ACCUM(DATA_WIDTH_ACCUM),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_core (
        .clk(clk), .rst(rst),
        .host_wr_addr_in(host_wr_addr_in), .host_wr_en_in(host_wr_en_in), .host_wr_data_in(host_wr_data_in),
        .axim_rd_addr_in(axim_rd_addr_in), .axim_rd_en_in(axim_rd_en_in), .axim_rd_data_out(axim_rd_data_out),
        
        .ctrl_rd_addr_a(ctrl_rd_addr_a), .ctrl_rd_en_a(ctrl_rd_en_a), .ctrl_a_valid(ctrl_a_valid), .ctrl_a_switch(ctrl_a_switch),
        .ctrl_rd_addr_b(ctrl_rd_addr_b), .ctrl_rd_en_b(ctrl_rd_en_b), .ctrl_b_accept_w(ctrl_b_accept_w), .ctrl_b_weight_index(ctrl_b_weight_index),
        .ctrl_rd_addr_c(ctrl_rd_addr_c), .ctrl_rd_en_c(ctrl_rd_en_c), .ctrl_c_valid(ctrl_c_valid), .ctrl_vpu_mode(ctrl_vpu_mode),
        .ctrl_wr_addr_d(ctrl_wr_addr_d), .ctrl_row_mask(ctrl_row_mask), .ctrl_col_mask(ctrl_col_mask),
        .core_writeback_valid(core_writeback_valid)
    );

    // 4. Helpers
    initial begin clk=0; forever #5 clk=~clk; end

    // Write Buffer Row
    task write_ib_row(input int addr, input int val_base, input bit is_int32);
        @(negedge clk);
        host_wr_addr_in = addr;
        host_wr_en_in = 1;
        for(int i=0; i<SYSTOLIC_ARRAY_WIDTH; i++) begin
            // 模拟数据: A/B 用低位，C 用全宽
            // 这里简单全填一样的值
            if (!is_int32) host_wr_data_in[i] = val_base; // Int8 Padding
            else           host_wr_data_in[i] = val_base; // Int32
        end
        @(negedge clk);
        host_wr_en_in = 0;
    endtask

    // Send Command
    task send_cmd(input int m, input int k, input int n, input int da, input int db, input int dc, input int dd);
        wait(cmd_ready);
        @(negedge clk);
        cmd_valid = 1;
        // Pack: D, C, B, A, N, K, M
        cmd_data = {10'(dd), 10'(dc), 10'(db), 10'(da), 8'(n), 8'(k), 8'(m)};
        @(negedge clk);
        cmd_valid = 0;
    endtask

    // 5. Main Test
    initial begin
        rst=1; 
        host_wr_en_in=0; axim_rd_en_in=0; cmd_valid=0;
        #100; rst=0; #20;

        $display("=== Test Start: Direct Core + CU ===");

        // --- Step 1: Load Data ---
        // A (Rows 0-15): Val = 1
        for(int i=0; i<16; i++) write_ib_row(i, 1, 0);
        
        // B (Rows 16-31): Val = 2
        for(int i=0; i<16; i++) write_ib_row(16+i, 2, 0);
        
        // C (Rows 32-47): Val = 5
        for(int i=0; i<16; i++) write_ib_row(32+i, 5, 1);

        $display("Data Loaded.");

        // --- Step 2: Send Command ---
        // M=16, K=16, N=16
        // A_Base=0, B_Base=16, C_Base=32, D_Base=48
        send_cmd(16, 16, 16, 0, 16, 32, 48);
        $display("Command Sent.");

        // --- Step 3: Monitor ---
        // Wait for Done IRQ
        wait(done_irq);
        $display("Done IRQ Received.");
        
        // --- Step 4: Verify Result ---
        // Read D (Rows 48-63)
        // Expected: 37
        #50;
        for(int i=0; i<16; i++) begin
            @(negedge clk);
            axim_rd_addr_in = 48+i;
            axim_rd_en_in = 1;
            @(negedge clk);
            axim_rd_en_in = 0;
            @(posedge clk); // Wait latency
            #1;
            
            $display("Row %0d: %d, %d ...", i, $signed(axim_rd_data_out[0]), $signed(axim_rd_data_out[1]));
            
            if($signed(axim_rd_data_out[0]) !== 37) 
                $error("Mismatch at Row %0d! Got %d", i, $signed(axim_rd_data_out[0]));
        end

        $finish;
    end

endmodule
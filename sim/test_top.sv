`timescale 1ns/1ps

module test_top;

    // ========================================================================
    // 1. 参数定义
    // ========================================================================
    parameter int ADDR_WIDTH           = 10;
    parameter int SYSTOLIC_ARRAY_WIDTH = 16;
    parameter int DATA_WIDTH_IN        = 8;
    parameter int DATA_WIDTH_ACCUM     = 32;
    
    localparam W = SYSTOLIC_ARRAY_WIDTH;

    // ========================================================================
    // 2. 信号声明
    // ========================================================================
    logic clk;
    logic rst;

    // Host Interface
    logic        cmd_valid;
    logic [63:0] cmd_data;
    logic        cmd_ready;
    logic        busy;
    logic        done_irq;

    // Host Data Loading
    logic [ADDR_WIDTH-1:0]       host_wr_addr_in;
    logic                        host_wr_en_in;
    logic [DATA_WIDTH_ACCUM-1:0] host_wr_data_in [W];

    // AXI Read Interface
    logic [ADDR_WIDTH-1:0]       axim_rd_addr_in;
    logic                        axim_rd_en_in;
    logic signed [DATA_WIDTH_ACCUM-1:0] axim_rd_data_out [W];

    // Interconnects
    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_a, ctrl_rd_addr_b, ctrl_rd_addr_c, ctrl_wr_addr_d;
    logic ctrl_rd_en_a, ctrl_a_valid, ctrl_a_switch, ctrl_psum_valid;
    logic ctrl_rd_en_b, ctrl_b_accept_w;
    logic [$clog2(W)-1:0]  ctrl_b_weight_index;
    logic ctrl_rd_en_c, ctrl_c_valid;
    logic [2:0] ctrl_vpu_mode;
    logic [W-1:0] ctrl_row_mask, ctrl_col_mask;
    logic core_writeback_valid;

    // ========================================================================
    // 3. 模块实例化 (Control Unit & TPU Core)
    // ========================================================================
    control_unit #(.ADDR_WIDTH(ADDR_WIDTH), .SYSTOLIC_ARRAY_WIDTH(W)) u_cu (
        .clk(clk), .rst(rst),
        .cmd_valid(cmd_valid), .cmd_data(cmd_data), .cmd_ready(cmd_ready),
        .busy(busy), .done_irq(done_irq),
        // A
        .ctrl_rd_addr_a(ctrl_rd_addr_a), .ctrl_rd_en_a(ctrl_rd_en_a),
        .ctrl_a_valid(ctrl_a_valid),     .ctrl_a_switch(ctrl_a_switch),
        .ctrl_psum_valid(ctrl_psum_valid),
        // B
        .ctrl_rd_addr_b(ctrl_rd_addr_b), .ctrl_rd_en_b(ctrl_rd_en_b),
        .ctrl_b_accept_w(ctrl_b_accept_w), .ctrl_b_weight_index(ctrl_b_weight_index),
        // C
        .ctrl_rd_addr_c(ctrl_rd_addr_c), .ctrl_rd_en_c(ctrl_rd_en_c),
        .ctrl_c_valid(ctrl_c_valid),     .ctrl_vpu_mode(ctrl_vpu_mode),
        // D
        .core_writeback_valid(core_writeback_valid), .ctrl_wr_addr_d(ctrl_wr_addr_d),
        .ctrl_row_mask(ctrl_row_mask),   .ctrl_col_mask(ctrl_col_mask)
    );

    tpu_core #(.SYSTOLIC_ARRAY_WIDTH(W), .DATA_WIDTH_IN(DATA_WIDTH_IN), .DATA_WIDTH_ACCUM(DATA_WIDTH_ACCUM), .ADDR_WIDTH(ADDR_WIDTH)) u_core (
        .clk(clk), .rst(rst),
        .host_wr_addr_in(host_wr_addr_in), .host_wr_en_in(host_wr_en_in), .host_wr_data_in(host_wr_data_in),
        .axim_rd_addr_in(axim_rd_addr_in), .axim_rd_en_in(axim_rd_en_in), .axim_rd_data_out(axim_rd_data_out),
        // Controls
        .ctrl_rd_addr_a(ctrl_rd_addr_a), .ctrl_rd_en_a(ctrl_rd_en_a), 
        .ctrl_a_valid(ctrl_a_valid), .ctrl_a_switch(ctrl_a_switch), .ctrl_psum_valid(ctrl_psum_valid), 
        .ctrl_rd_addr_b(ctrl_rd_addr_b), .ctrl_rd_en_b(ctrl_rd_en_b), 
        .ctrl_b_accept_w(ctrl_b_accept_w), .ctrl_b_weight_index(ctrl_b_weight_index),
        .ctrl_rd_addr_c(ctrl_rd_addr_c), .ctrl_rd_en_c(ctrl_rd_en_c), 
        .ctrl_c_valid(ctrl_c_valid), .ctrl_vpu_mode(ctrl_vpu_mode),
        .ctrl_wr_addr_d(ctrl_wr_addr_d),
        .ctrl_row_mask(ctrl_row_mask), .ctrl_col_mask(ctrl_col_mask),
        .core_writeback_valid(core_writeback_valid)
    );

    // ========================================================================
    // 4. 辅助定义
    // ========================================================================
    typedef struct packed {
        logic [ADDR_WIDTH-1:0] addr_d;
        logic [ADDR_WIDTH-1:0] addr_c;
        logic [ADDR_WIDTH-1:0] addr_b;
        logic [ADDR_WIDTH-1:0] addr_a;
        logic [7:0]            len_n;
        logic [7:0]            len_k;
        logic [7:0]            len_m;
    } command_t;

    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100MHz
    end

    // 发送指令任务
    task send_cmd(input logic [ADDR_WIDTH-1:0] ad, ac, ab, aa, input int k, n);
        command_t cmd;
        cmd.addr_d = ad; cmd.addr_c = ac; cmd.addr_b = ab; cmd.addr_a = aa;
        cmd.len_n  = 8'(n); cmd.len_k  = 8'(k); cmd.len_m  = 8'd16; 
        wait(!rst && cmd_ready);
        @(posedge clk); cmd_valid <= 1; cmd_data <= cmd;
        @(posedge clk); cmd_valid <= 0;
        $display("[%0t] [Host] Command Sent: A@%h, B@%h -> D@%h (K=%0d, N=%0d)", $time, aa, ab, ad, k, n);
    endtask

    // 数据加载任务
    task load_matrix_region(input int base_addr, input int num_rows, input int active_lanes, input int val);
        @(posedge clk);
        for(int i=0; i<num_rows; i++) begin
            host_wr_en_in <= 1;
            host_wr_addr_in <= base_addr + i;
            for(int w=0; w<W; w++) begin
                if (w < active_lanes) host_wr_data_in[w] <= val; 
                else host_wr_data_in[w] <= 32'd0; 
            end
            @(posedge clk);
        end
        host_wr_en_in <= 0;
    endtask

    // ========================================================================
    // 5. 主流程
    // ========================================================================
    initial begin
        rst = 1;
        cmd_valid = 0; cmd_data = 0;
        host_wr_en_in = 0; axim_rd_en_in = 0;
        
        repeat(10) @(posedge clk);
        rst = 0;
        $display("[%0t] [Test] Reset released.", $time);
        
        // --- 1. 初始化内存 ---
        $display("[%0t] [Test] Initializing Memory...", $time);
        // A1: 值=1 (0x100)
        load_matrix_region(10'h100, 16, 16, 1); 
        // A2: 值=2 (0x120) - 用于第二个任务
        load_matrix_region(10'h120, 16, 16, 2);
        // B:  值=1 (0x200) - 两个任务共享
        load_matrix_region(10'h200, 16, 16, 1);
        // C:  值=1 (0x300) - Bias
        load_matrix_region(10'h300, 16, 8, 1); 
        
        $display("[%0t] [Test] Memory Initialized.", $time);
        repeat(10) @(posedge clk);

        // --- 2. 连续发送两个任务 (Batch K=8, N=8) ---
        $display("\n=== Starting Multi-Task Batch (K=8, N=8) ===");
        
        // Task 1: 1 * 1 * 8 + 1 = 9
        send_cmd(10'h400, 10'h300, 10'h200, 10'h100, 8, 8);
        
        // Task 2: 2 * 1 * 8 + 1 = 17 (0x11)
        // 紧随其后发送，测试 FIFO 和 流水线衔接
        send_cmd(10'h420, 10'h300, 10'h200, 10'h120, 8, 8);

        // --- 3. 等待两个任务完成 ---
        // 等待第一次 Done IRQ
        wait(done_irq); 
        $display("[%0t] [IRQ] Task 1 Completed.", $time);
        @(posedge clk); 
        wait(!done_irq); // 等待 IRQ 拉低

        // 等待第二次 Done IRQ
        wait(done_irq);
        $display("[%0t] [IRQ] Task 2 Completed.", $time);
        @(posedge clk);

        // --- 4. 验证结果 ---
        $display("\n=== Verifying Output ===");
        
        // 验证 Task 1 (0x400)
        axim_rd_en_in <= 1; axim_rd_addr_in <= 10'h400; @(posedge clk);
        axim_rd_en_in <= 0; @(posedge clk);
        
        $display("Task 1 Result[0]: %d (Expected 9)", axim_rd_data_out[0]);
        if(axim_rd_data_out[0] === 9) $display("[PASS] Task 1 OK");
        else $error("[FAIL] Task 1 Mismatch");

        // 验证 Task 2 (0x420)
        axim_rd_en_in <= 1; axim_rd_addr_in <= 10'h420; @(posedge clk);
        axim_rd_en_in <= 0; @(posedge clk);
        
        $display("Task 2 Result[0]: %d (Expected 17)", axim_rd_data_out[0]);
        if(axim_rd_data_out[0] === 17) $display("[PASS] Task 2 OK");
        else $error("[FAIL] Task 2 Mismatch");

        repeat(50) @(posedge clk);
        $finish;
    end
    
    // 监控器
    always @(posedge clk) begin
        if (core_writeback_valid) begin
            $display("[%0t] [Monitor] Writeback! Row=%0d, Data[0]=%h", 
                     $time, u_cu.wb_row_cnt, u_core.aligned_wr_data[0]);
        end
    end

endmodule
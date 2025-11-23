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

    // --- Host Interface (Control Unit) ---
    logic        cmd_valid;
    logic [63:0] cmd_data;
    logic        cmd_ready;
    logic        busy;
    logic        done_irq;

    // --- Host Data Interface (TPU Core - Input Loading) ---
    logic [ADDR_WIDTH-1:0]       host_wr_addr_in;
    logic                        host_wr_en_in;
    logic [DATA_WIDTH_ACCUM-1:0] host_wr_data_in [W];

    // --- AXI Master Interface (TPU Core - Result Reading) ---
    logic [ADDR_WIDTH-1:0]       axim_rd_addr_in;
    logic                        axim_rd_en_in;
    logic signed [DATA_WIDTH_ACCUM-1:0] axim_rd_data_out [W];

    // --- Internal Interconnects (CU <-> Core) ---
    // A-Flow
    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_a;
    logic                  ctrl_rd_en_a;
    logic                  ctrl_a_valid;
    logic                  ctrl_a_switch;
    logic                  ctrl_psum_valid; // [NEW] Psum Valid Link
    
    // B-Flow
    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_b;
    logic                  ctrl_rd_en_b;
    logic                  ctrl_b_accept_w;
    logic [$clog2(W)-1:0]  ctrl_b_weight_index;
    
    // C-Flow
    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_c;
    logic                  ctrl_rd_en_c;
    logic                  ctrl_c_valid;
    logic [2:0]            ctrl_vpu_mode;
    
    // D-Flow / Masks / Feedback
    logic [ADDR_WIDTH-1:0] ctrl_wr_addr_d;
    logic [W-1:0]          ctrl_row_mask;
    logic [W-1:0]          ctrl_col_mask;
    logic                  core_writeback_valid;

    // ========================================================================
    // 3. 模块实例化
    // ========================================================================

    // Control Unit Instance
    control_unit #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .SYSTOLIC_ARRAY_WIDTH(W)
    ) u_cu (
        .clk(clk), .rst(rst),
        .cmd_valid(cmd_valid), .cmd_data(cmd_data), .cmd_ready(cmd_ready),
        .busy(busy), .done_irq(done_irq),

        .ctrl_rd_addr_a(ctrl_rd_addr_a), .ctrl_rd_en_a(ctrl_rd_en_a),
        .ctrl_a_valid(ctrl_a_valid),     .ctrl_a_switch(ctrl_a_switch),
        .ctrl_psum_valid(ctrl_psum_valid), // [NEW] Connected

        .ctrl_rd_addr_b(ctrl_rd_addr_b), .ctrl_rd_en_b(ctrl_rd_en_b),
        .ctrl_b_accept_w(ctrl_b_accept_w), .ctrl_b_weight_index(ctrl_b_weight_index),

        .ctrl_rd_addr_c(ctrl_rd_addr_c), .ctrl_rd_en_c(ctrl_rd_en_c),
        .ctrl_c_valid(ctrl_c_valid),     .ctrl_vpu_mode(ctrl_vpu_mode),

        .core_writeback_valid(core_writeback_valid),
        .ctrl_wr_addr_d(ctrl_wr_addr_d),
        .ctrl_row_mask(ctrl_row_mask),   .ctrl_col_mask(ctrl_col_mask)
    );

    // TPU Core Instance
    tpu_core #(
        .SYSTOLIC_ARRAY_WIDTH(W),
        .DATA_WIDTH_IN(DATA_WIDTH_IN),
        .DATA_WIDTH_ACCUM(DATA_WIDTH_ACCUM),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_core (
        .clk(clk), .rst(rst),
        // Host Write
        .host_wr_addr_in(host_wr_addr_in), .host_wr_en_in(host_wr_en_in), .host_wr_data_in(host_wr_data_in),
        // AXI Read
        .axim_rd_addr_in(axim_rd_addr_in), .axim_rd_en_in(axim_rd_en_in), .axim_rd_data_out(axim_rd_data_out),
        // Controls
        .ctrl_rd_addr_a(ctrl_rd_addr_a), .ctrl_rd_en_a(ctrl_rd_en_a), 
        .ctrl_a_valid(ctrl_a_valid), .ctrl_a_switch(ctrl_a_switch),
        .ctrl_psum_valid(ctrl_psum_valid), // [NEW] Connected
        
        .ctrl_rd_addr_b(ctrl_rd_addr_b), .ctrl_rd_en_b(ctrl_rd_en_b), 
        .ctrl_b_accept_w(ctrl_b_accept_w), .ctrl_b_weight_index(ctrl_b_weight_index),
        
        .ctrl_rd_addr_c(ctrl_rd_addr_c), .ctrl_rd_en_c(ctrl_rd_en_c), 
        .ctrl_c_valid(ctrl_c_valid), .ctrl_vpu_mode(ctrl_vpu_mode),
        
        .ctrl_wr_addr_d(ctrl_wr_addr_d),
        .ctrl_row_mask(ctrl_row_mask), .ctrl_col_mask(ctrl_col_mask),
        // Feedback
        .core_writeback_valid(core_writeback_valid)
    );

    // ========================================================================
    // 4. 辅助结构体与任务
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

    // 时钟生成
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100MHz
    end

    // 任务：发送指令
    task send_cmd(input logic [ADDR_WIDTH-1:0] ad, ac, ab, aa, input int k, n);
        command_t cmd;
        cmd.addr_d = ad;
        cmd.addr_c = ac;
        cmd.addr_b = ab;
        cmd.addr_a = aa;
        cmd.len_n  = 8'(n); 
        cmd.len_k  = 8'(k); 
        cmd.len_m  = 8'd16; 
        
        wait(!rst && cmd_ready);
        @(posedge clk);
        cmd_valid <= 1;
        cmd_data  <= cmd;
        @(posedge clk);
        cmd_valid <= 0;
        $display("[%0t] [Host] Command Sent: K=%0d, N=%0d (Addr A:%h, D:%h)", $time, k, n, aa, ad);
    endtask

    // 任务：预加载 Buffer 数据
    task load_buffer_data(input int start_addr, input int count, input int val_a, input int val_b);
        $display("[%0t] [Test] Pre-loading buffers...", $time);
        @(posedge clk);
        for(int i=0; i<count; i++) begin
            host_wr_en_in <= 1;
            host_wr_addr_in <= start_addr + i;
            for(int w=0; w<W; w++) begin
                // [FIXED] Hex Syntax Error Fix
                host_wr_data_in[w] <= (val_b << 16) | (val_a & 16'hFFFF); 
            end
            @(posedge clk);
        end
        host_wr_en_in <= 0;
        $display("[%0t] [Test] Buffer load complete.", $time);
    endtask

    // ========================================================================
    // 5. 主测试流程
    // ========================================================================
    initial begin
        // 初始化
        rst = 1;
        cmd_valid = 0; cmd_data = 0;
        host_wr_en_in = 0; host_wr_addr_in = 0;
        axim_rd_en_in = 0; axim_rd_addr_in = 0;
        
        // Reset
        repeat(10) @(posedge clk);
        rst = 0;
        $display("[%0t] [Test] Reset released.", $time);
        
        // ------------------------------------------------------------
        // Step 1: 预加载数据
        // ------------------------------------------------------------
        // 写入 1, 1 -> 结果应为 1*1*16 + Bias = 16 + Bias
        load_buffer_data(10'h100, 32, 1, 1); 
        
        repeat(10) @(posedge clk);

        // ------------------------------------------------------------
        // Step 2: Batch 1 (K=8, N=8)
        // ------------------------------------------------------------
        $display("\n=== Starting Batch 1 (K=8, N=8) ===");
        fork
            begin
                send_cmd(10'h200, 10'h100, 10'h100, 10'h100, 8, 8);
                send_cmd(10'h210, 10'h100, 10'h100, 10'h100, 8, 8);
            end
        join

        // 等待 IRQ
        wait(done_irq); 
        $display("[%0t] [IRQ] Batch 1 - Task 1 Done", $time);
        @(posedge clk); wait(!done_irq);

        wait(done_irq); 
        $display("[%0t] [IRQ] Batch 1 - Task 2 Done", $time);
        @(posedge clk); wait(!done_irq);

        $display("[%0t] [Test] Batch 1 Completed.", $time);
        repeat(20) @(posedge clk);

        // ------------------------------------------------------------
        // Step 3: Batch 2 (K=16, N=16)
        // ------------------------------------------------------------
        $display("\n=== Starting Batch 2 (K=16, N=16) ===");
        send_cmd(10'h300, 10'h100, 10'h100, 10'h100, 16, 16);

        wait(done_irq);
        $display("[%0t] [IRQ] Batch 2 - Task 3 Done", $time);
        @(posedge clk);

        // ------------------------------------------------------------
        // Step 4: 结果验证
        // ------------------------------------------------------------
        $display("\n=== Verifying Output (Reading from Dest Addr 0x200) ===");
        axim_rd_en_in <= 1;
        axim_rd_addr_in <= 10'h200; 
        @(posedge clk);
        axim_rd_en_in <= 0;
        
        @(posedge clk);
        $display("[%0t] [AXI Read] Data at 0x200:", $time);
        for(int i=0; i<W; i++) begin
            $write("%d ", axim_rd_data_out[i]);
        end
        $write("\n");

        if (axim_rd_data_out[0] !== 0 && axim_rd_data_out[8] === 0) 
            $display("[PASS] Masking Logic seems correct (Col 0 active, Col 8 inactive).");
        else
            $warning("[WARN] Masking check failed or Data is zero.");

        repeat(20) @(posedge clk);
        $finish;
    end

    // Monitor
    always @(posedge clk) begin
        if (core_writeback_valid) begin
            $display("[%0t] [Core->CU] Writeback Valid! Row Index: %0d", $time, u_cu.wb_row_cnt);
        end
    end

endmodule
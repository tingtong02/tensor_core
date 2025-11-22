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
        // Host Write (Pre-load data)
        .host_wr_addr_in(host_wr_addr_in), .host_wr_en_in(host_wr_en_in), .host_wr_data_in(host_wr_data_in),
        // AXI Read (Read result)
        .axim_rd_addr_in(axim_rd_addr_in), .axim_rd_en_in(axim_rd_en_in), .axim_rd_data_out(axim_rd_data_out),
        // Controls from CU
        .ctrl_rd_addr_a(ctrl_rd_addr_a), .ctrl_rd_en_a(ctrl_rd_en_a), .ctrl_a_valid(ctrl_a_valid), .ctrl_a_switch(ctrl_a_switch),
        .ctrl_rd_addr_b(ctrl_rd_addr_b), .ctrl_rd_en_b(ctrl_rd_en_b), .ctrl_b_accept_w(ctrl_b_accept_w), .ctrl_b_weight_index(ctrl_b_weight_index),
        .ctrl_rd_addr_c(ctrl_rd_addr_c), .ctrl_rd_en_c(ctrl_rd_en_c), .ctrl_c_valid(ctrl_c_valid), .ctrl_vpu_mode(ctrl_vpu_mode),
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
        cmd.len_n  = 8'(n); // N 决定列掩码 (Cols)
        cmd.len_k  = 8'(k); // K 决定行掩码 (Rows)
        cmd.len_m  = 8'd16; // M 不影响硬件逻辑，保留默认
        
        wait(!rst && cmd_ready);
        @(posedge clk);
        cmd_valid <= 1;
        cmd_data  <= cmd;
        @(posedge clk);
        cmd_valid <= 0;
        $display("[%0t] [Host] Command Sent: K=%0d, N=%0d (Addr A:%h, D:%h)", $time, k, n, aa, ad);
    endtask

    // 任务：预加载 Buffer 数据
    // 简单起见，给 A/B/C Buffer 的相同地址写入相同数据
    task load_buffer_data(input int start_addr, input int count, input int val_a, input int val_b);
        $display("[%0t] [Test] Pre-loading buffers...", $time);
        @(posedge clk);
        for(int i=0; i<count; i++) begin
            host_wr_en_in <= 1;
            host_wr_addr_in <= start_addr + i;
            for(int w=0; w<W; w++) begin
                // Pack 4 bytes for input A/B (simulated) or just fill lower bits
                // 这里简单将输入 A 设为 val_a, B 设为 val_b
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
        // Step 1: 预加载数据 (模拟 Host 写内存)
        // ------------------------------------------------------------
        // 向地址 0x100~0x10F 写入数据 (供 Task 1 使用)
        // 设 A=1, B=1. 预期结果是累加值
        load_buffer_data(10'h100, 32, 1, 1); 
        
        repeat(10) @(posedge clk);

        // ------------------------------------------------------------
        // Step 2: Batch 1 - 两个小矩阵任务 (K=8, N=8)
        // ------------------------------------------------------------
        $display("\n=== Starting Batch 1 (K=8, N=8) ===");
        // 假设同一批次参数相同
        fork
            begin
                // Task 1: Source Addr 0x100, Dest 0x200
                send_cmd(10'h200, 10'h100, 10'h100, 10'h100, 8, 8);
                // Task 2: Source Addr 0x100, Dest 0x210 (紧随其后)
                send_cmd(10'h210, 10'h100, 10'h100, 10'h100, 8, 8);
            end
        join

        // 等待 Batch 1 全部完成 (两个 IRQ)
        wait(done_irq); 
        $display("[%0t] [IRQ] Batch 1 - Task 1 Done", $time);
        @(posedge clk); wait(!done_irq); // 等待 IRQ 拉低

        wait(done_irq); 
        $display("[%0t] [IRQ] Batch 1 - Task 2 Done", $time);
        @(posedge clk); wait(!done_irq);

        $display("[%0t] [Test] Batch 1 Completed. FIFO should be empty.", $time);
        repeat(20) @(posedge clk); // Gap between batches

        // ------------------------------------------------------------
        // Step 3: Batch 2 - 一个全尺寸任务 (K=16, N=16)
        // ------------------------------------------------------------
        $display("\n=== Starting Batch 2 (K=16, N=16) ===");
        // Task 3: Source Addr 0x100, Dest 0x300
        send_cmd(10'h300, 10'h100, 10'h100, 10'h100, 16, 16);

        wait(done_irq);
        $display("[%0t] [IRQ] Batch 2 - Task 3 Done", $time);
        @(posedge clk);

        // ------------------------------------------------------------
        // Step 4: 结果验证 (读取 Output Buffer)
        // ------------------------------------------------------------
        $display("\n=== Verifying Output (Reading from Dest Addr 0x200) ===");
        // 读取 Task 1 的结果 (地址 0x200)
        // 由于 Task 1 的 N=8, 我们期望前 8 个数据有效，后 8 个可能被 Mask 掉(保持0或旧值)
        axim_rd_en_in <= 1;
        axim_rd_addr_in <= 10'h200; // 读第一行结果
        @(posedge clk);
        axim_rd_en_in <= 0;
        
        @(posedge clk); // 等待读延迟
        $display("[%0t] [AXI Read] Data at 0x200:", $time);
        for(int i=0; i<W; i++) begin
            $write("%d ", axim_rd_data_out[i]);
        end
        $write("\n");

        // 简单断言：如果是 8x8 矩阵，前8个数据应该非零(因为我们填了1)，后8个应为0(被Mask)
        // 注意：具体数值取决于 Systolic Array 的内部累加逻辑，这里只检查 Mask 效果
        if (axim_rd_data_out[0] !== 0 && axim_rd_data_out[8] === 0) 
            $display("[PASS] Masking Logic seems correct (Col 0 active, Col 8 inactive).");
        else
            $warning("[WARN] Masking check failed or Data is zero. Check array calculation.");

        repeat(20) @(posedge clk);
        $finish;
    end

    // ========================================================================
    // 6. 监控器 (Monitor)
    // ========================================================================
    // 监控核心写回信号，确认握手成功
    always @(posedge clk) begin
        if (core_writeback_valid) begin
            $display("[%0t] [Core->CU] Writeback Valid! Row Index: %0d", $time, u_cu.wb_row_cnt);
        end
    end

endmodule
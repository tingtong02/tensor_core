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

    // --- Host Interface ---
    logic        cmd_valid;
    logic [63:0] cmd_data;
    logic        cmd_ready;
    logic        busy;
    logic        done_irq;

    // --- Host Data Loading (Unified Buffer Interface) ---
    logic [ADDR_WIDTH-1:0]       host_wr_addr_in;
    logic                        host_wr_en_in;
    logic [DATA_WIDTH_ACCUM-1:0] host_wr_data_in [W];

    // --- AXI Read Interface ---
    logic [ADDR_WIDTH-1:0]       axim_rd_addr_in;
    logic                        axim_rd_en_in;
    logic signed [DATA_WIDTH_ACCUM-1:0] axim_rd_data_out [W];

    // --- Internal Interconnects (CU <-> Core) ---
    // A-Flow
    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_a;
    logic                  ctrl_rd_en_a;
    logic                  ctrl_a_valid;
    logic                  ctrl_a_switch;
    logic                  ctrl_psum_valid; 
    
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
    
    // D-Flow
    logic [ADDR_WIDTH-1:0] ctrl_wr_addr_d;
    logic [W-1:0]          ctrl_row_mask;
    logic [W-1:0]          ctrl_col_mask;
    logic                  core_writeback_valid;

    // ========================================================================
    // 3. 模块实例化
    // ========================================================================

    control_unit #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .SYSTOLIC_ARRAY_WIDTH(W)
    ) u_cu (
        .clk(clk), .rst(rst),
        .cmd_valid(cmd_valid), .cmd_data(cmd_data), .cmd_ready(cmd_ready),
        .busy(busy), .done_irq(done_irq),

        // A connection
        .ctrl_rd_addr_a(ctrl_rd_addr_a), .ctrl_rd_en_a(ctrl_rd_en_a),
        .ctrl_a_valid(ctrl_a_valid),     .ctrl_a_switch(ctrl_a_switch),
        .ctrl_psum_valid(ctrl_psum_valid),

        // B connection
        .ctrl_rd_addr_b(ctrl_rd_addr_b), .ctrl_rd_en_b(ctrl_rd_en_b),
        .ctrl_b_accept_w(ctrl_b_accept_w), .ctrl_b_weight_index(ctrl_b_weight_index),

        // C connection
        .ctrl_rd_addr_c(ctrl_rd_addr_c), .ctrl_rd_en_c(ctrl_rd_en_c),
        .ctrl_c_valid(ctrl_c_valid),     .ctrl_vpu_mode(ctrl_vpu_mode),

        // D connection & Masks
        .core_writeback_valid(core_writeback_valid),
        .ctrl_wr_addr_d(ctrl_wr_addr_d),
        .ctrl_row_mask(ctrl_row_mask),   .ctrl_col_mask(ctrl_col_mask)
    );

    tpu_core #(
        .SYSTOLIC_ARRAY_WIDTH(W),
        .DATA_WIDTH_IN(DATA_WIDTH_IN),
        .DATA_WIDTH_ACCUM(DATA_WIDTH_ACCUM),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_core (
        .clk(clk), .rst(rst),
        .host_wr_addr_in(host_wr_addr_in), .host_wr_en_in(host_wr_en_in), .host_wr_data_in(host_wr_data_in),
        .axim_rd_addr_in(axim_rd_addr_in), .axim_rd_en_in(axim_rd_en_in), .axim_rd_data_out(axim_rd_data_out),
        
        // A
        .ctrl_rd_addr_a(ctrl_rd_addr_a), .ctrl_rd_en_a(ctrl_rd_en_a), 
        .ctrl_a_valid(ctrl_a_valid), .ctrl_a_switch(ctrl_a_switch),
        .ctrl_psum_valid(ctrl_psum_valid), 
        
        // B
        .ctrl_rd_addr_b(ctrl_rd_addr_b), .ctrl_rd_en_b(ctrl_rd_en_b), 
        .ctrl_b_accept_w(ctrl_b_accept_w), .ctrl_b_weight_index(ctrl_b_weight_index),
        
        // C
        .ctrl_rd_addr_c(ctrl_rd_addr_c), .ctrl_rd_en_c(ctrl_rd_en_c), 
        .ctrl_c_valid(ctrl_c_valid), .ctrl_vpu_mode(ctrl_vpu_mode),
        
        // D
        .ctrl_wr_addr_d(ctrl_wr_addr_d),
        .ctrl_row_mask(ctrl_row_mask), .ctrl_col_mask(ctrl_col_mask),
        .core_writeback_valid(core_writeback_valid)
    );

    // ========================================================================
    // 4. 辅助任务
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

    // 发送指令
    task send_cmd(input logic [ADDR_WIDTH-1:0] ad, ac, ab, aa, input int k, n);
        command_t cmd;
        cmd.addr_d = ad; 
        cmd.addr_c = ac; 
        cmd.addr_b = ab; 
        cmd.addr_a = aa;
        cmd.len_n  = 8'(n); cmd.len_k  = 8'(k); cmd.len_m  = 8'd16; 
        
        wait(!rst && cmd_ready);
        @(posedge clk); cmd_valid <= 1; cmd_data <= cmd;
        @(posedge clk); cmd_valid <= 0;
        $display("[%0t] [Host] Command Sent: A@%h, B@%h, C@%h -> D@%h (K=%0d, N=%0d)", 
                 $time, aa, ab, ac, ad, k, n);
    endtask

    // [通用数据加载任务]
    // 向指定基地址写入 count 行数据
    // active_lanes: 这一行中有效数据的个数 (0~W)
    // val: 有效数据的值
    task load_matrix_region(
        input int base_addr, 
        input int num_rows,     // 需要写入多少行
        input int active_lanes, // 每行有多少个有效元素 (列数)
        input int val           // 数据值
    );
        @(posedge clk);
        for(int i=0; i<num_rows; i++) begin
            host_wr_en_in <= 1;
            host_wr_addr_in <= base_addr + i;
            for(int w=0; w<W; w++) begin
                if (w < active_lanes) begin
                    // 有效数据: 写入 val
                    // 注意: 即便是 int8 (A/B), 写入低8位即可，高位会被 Core 截断
                    host_wr_data_in[w] <= val; 
                end else begin
                    // 无效数据: 填充 0
                    host_wr_data_in[w] <= 32'd0; 
                end
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
        
        // --- 1. 数据准备 ---
        $display("[%0t] [Test] Initializing Memory...", $time);
        
        // Matrix A (Input): Addr 0x100
        // 写入 8 行有效数据 (因为 K=8)，每行 16 个 1 (广播)
        // 实际上对于 A 矩阵，PE 会读取 active_len_k 行。为了安全我们填满 16 行。
        // A 是 int8，我们写入 1 (32'h00000001)，Core 只取低8位。
        load_matrix_region(10'h100, 16, 16, 1); 

        // Matrix B (Weight): Addr 0x200
        // B 是 int8，同上。
        load_matrix_region(10'h200, 16, 16, 1);

        // Matrix C (Bias): Addr 0x300
        // Bias 是 int32。我们只填充前 8 列 (N=8)，值为 1。
        // 后 8 列填 0，用于验证 Mask 是否生效 (无效列应输出 0)。
        load_matrix_region(10'h300, 16, 8, 1); 

        $display("[%0t] [Test] Memory Initialized.", $time);
        repeat(10) @(posedge clk);

        // --- 2. 发送指令 ---
        $display("\n=== Starting Task (K=8, N=8) ===");
        // 指令：Read A from 0x100, B from 0x200, C from 0x300, Write D to 0x400
        send_cmd(10'h400, 10'h300, 10'h200, 10'h100, 8, 8);

        // --- 3. 等待完成 ---
        wait(done_irq); 
        $display("[%0t] [IRQ] Task Done", $time);
        @(posedge clk);

        // --- 4. 结果验证 ---
        $display("\n=== Verifying Output (Reading D from 0x400) ===");
        
        // 读取第一行结果 (Row 0)
        axim_rd_en_in <= 1;
        axim_rd_addr_in <= 10'h400; 
        @(posedge clk);
        axim_rd_en_in <= 0;
        
        @(posedge clk); // 等待读出
        
        // 打印数据
        $display("--- Output Data Dump (Row 0) ---");
        for(int i=0; i<W; i++) begin
            $display("Col[%02d]: %h", i, axim_rd_data_out[i]);
        end
        
        // 自动断言
        // 预期: (A=1 * B=1 * K=8) + Bias=1 = 9
        if (axim_rd_data_out[0] === 32'h00000009) 
            $display("[PASS] Col 0 Data Correct (9)");
        else 
            $error("[FAIL] Col 0 Data Mismatch! Expected 9, Got %d", axim_rd_data_out[0]);

        // 验证 Mask (Col 8 应该是 0)
        // 因为 Bias C 的第 8 列我们填了 0，且 Mask 禁用了该列计算，所以结果必须是 0
        if (axim_rd_data_out[8] === 32'h0) 
            $display("[PASS] Col 8 Data Correct (0, Masked)");
        else 
            $error("[FAIL] Col 8 Data Mismatch! Expected 0, Got %d", axim_rd_data_out[8]);

        repeat(20) @(posedge clk);
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
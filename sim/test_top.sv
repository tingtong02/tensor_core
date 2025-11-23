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

    // CU <-> Core Interconnects
    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_a;
    logic                  ctrl_rd_en_a;
    logic                  ctrl_a_valid;
    logic                  ctrl_a_switch;
    logic                  ctrl_psum_valid; 
    
    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_b;
    logic                  ctrl_rd_en_b;
    logic                  ctrl_b_accept_w;
    logic [$clog2(W)-1:0]  ctrl_b_weight_index;
    
    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_c;
    logic                  ctrl_rd_en_c;
    logic                  ctrl_c_valid;
    logic [2:0]            ctrl_vpu_mode;
    
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

        .ctrl_rd_addr_a(ctrl_rd_addr_a), .ctrl_rd_en_a(ctrl_rd_en_a),
        .ctrl_a_valid(ctrl_a_valid),     .ctrl_a_switch(ctrl_a_switch),
        .ctrl_psum_valid(ctrl_psum_valid),

        .ctrl_rd_addr_b(ctrl_rd_addr_b), .ctrl_rd_en_b(ctrl_rd_en_b),
        .ctrl_b_accept_w(ctrl_b_accept_w), .ctrl_b_weight_index(ctrl_b_weight_index),

        .ctrl_rd_addr_c(ctrl_rd_addr_c), .ctrl_rd_en_c(ctrl_rd_en_c),
        .ctrl_c_valid(ctrl_c_valid),     .ctrl_vpu_mode(ctrl_vpu_mode),

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
        
        .ctrl_rd_addr_a(ctrl_rd_addr_a), .ctrl_rd_en_a(ctrl_rd_en_a), 
        .ctrl_a_valid(ctrl_a_valid), .ctrl_a_switch(ctrl_a_switch),
        .ctrl_psum_valid(ctrl_psum_valid), 
        
        .ctrl_rd_addr_b(ctrl_rd_addr_b), .ctrl_rd_en_b(ctrl_rd_en_b), 
        .ctrl_b_accept_w(ctrl_b_accept_w), .ctrl_b_weight_index(ctrl_b_weight_index),
        
        .ctrl_rd_addr_c(ctrl_rd_addr_c), .ctrl_rd_en_c(ctrl_rd_en_c), 
        .ctrl_c_valid(ctrl_c_valid), .ctrl_vpu_mode(ctrl_vpu_mode),
        
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
        cmd.addr_d = ad; cmd.addr_c = ac; cmd.addr_b = ab; cmd.addr_a = aa;
        cmd.len_n  = 8'(n); cmd.len_k  = 8'(k); cmd.len_m  = 8'd16; 
        wait(!rst && cmd_ready);
        @(posedge clk); cmd_valid <= 1; cmd_data <= cmd;
        @(posedge clk); cmd_valid <= 0;
        $display("[%0t] [Host] Command Sent: K=%0d, N=%0d", $time, k, n);
    endtask

    // [改进] 预加载数据：支持指定有效通道数 (Active Lanes)
    // 只有 0 ~ active_lanes-1 的通道会被写入 val_a/val_b，其余通道填充 0
    task load_buffer_data(
        input int start_addr, 
        input int count, 
        input int val_a, 
        input int val_b,
        input int active_lanes // NEW: 仅填充前多少个通道
    );
        $display("[%0t] [Test] Pre-loading buffers (Active Lanes: %0d)...", $time, active_lanes);
        @(posedge clk);
        for(int i=0; i<count; i++) begin
            host_wr_en_in <= 1;
            host_wr_addr_in <= start_addr + i;
            for(int w=0; w<W; w++) begin
                if (w < active_lanes) begin
                    // 有效区域: 填入测试数据 (打包 A 和 B)
                    // A 在低16位, B 在高16位 (或根据你的具体打包逻辑)
                    host_wr_data_in[w] <= (val_b << 16) | (val_a & 16'hFFFF); 
                end else begin
                    // 无效区域: 显式填充 0
                    // 这样可以验证：即使 Mask 逻辑失效，只要 PE 不计算，结果也应该是 Clean 的 0 (或者 Bias)
                    host_wr_data_in[w] <= 32'd0; 
                end
            end
            @(posedge clk);
        end
        host_wr_en_in <= 0;
        $display("[%0t] [Test] Buffer load complete.", $time);
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
        
        // 1. 加载数据 (只填充前 8 个通道)
        // 这样 Bias C 的前 8 个是 0x10001, 后 8 个是 0
        // Input A 的前 8 行是 1, 后 8 行是 0
        // Input B 的前 8 列是 1, 后 8 列是 0
        load_buffer_data(10'h100, 32, 1, 1, 8); // Start=0x100, Count=32, A=1, B=1, Lanes=8
        
        repeat(10) @(posedge clk);

        // 2. 发送单次指令 (K=8, N=8)
        $display("\n=== Starting Task (K=8, N=8) ===");
        // Source=0x100, Dest=0x200
        send_cmd(10'h200, 10'h100, 10'h100, 10'h100, 8, 8);

        // 3. 等待完成
        wait(done_irq); 
        $display("[%0t] [IRQ] Task Done", $time);
        @(posedge clk);

        // 4. 验证结果
        $display("\n=== Verifying Output (Reading 0x200) ===");
        axim_rd_en_in <= 1;
        axim_rd_addr_in <= 10'h200; 
        @(posedge clk);
        axim_rd_en_in <= 0;
        
        @(posedge clk); // 等待读出
        
        // 打印所有通道结果
        $display("--- Output Data Dump ---");
        for(int i=0; i<W; i++) begin
            $display("Col[%02d]: %h", i, axim_rd_data_out[i]);
        end
        
        // 自动断言
        if (axim_rd_data_out[0] === 32'h00010009) 
            $display("[PASS] Col 0 Data Correct (0x10009)");
        else 
            $error("[FAIL] Col 0 Data Mismatch! Expected 0x10009, Got %h", axim_rd_data_out[0]);

        // 检查无效通道是否为 0
        // 注意：因为我们上面把 Buffer C 的后 8 个通道填成了 0 (Bias=0)
        // 且 Column Mask 禁用了后 8 列 (PE 不计算, Psum=0)
        // 所以预期结果应该是 0 + 0 = 0
        if (axim_rd_data_out[8] === 32'h0) 
            $display("[PASS] Col 8 Data Correct (0x0, Clean Zero)");
        else 
            $error("[FAIL] Col 8 Data Mismatch! Expected 0x0, Got %h", axim_rd_data_out[8]);

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
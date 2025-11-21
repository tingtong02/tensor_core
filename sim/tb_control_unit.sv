`timescale 1ns/1ps

module tb_control_unit;

    // ========================================================================
    // 1. 参数与信号声明
    // ========================================================================
    parameter int ADDR_WIDTH = 10;
    parameter int SYSTOLIC_ARRAY_WIDTH = 16;
    localparam W = SYSTOLIC_ARRAY_WIDTH;

    logic clk;
    logic rst;

    // Host Interface
    logic        cmd_valid;
    logic [63:0] cmd_data;
    logic        cmd_ready;
    logic        busy;
    logic        done_irq;

    // TPU Core Interface
    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_a;
    logic                  ctrl_rd_en_a;
    logic                  ctrl_a_valid;
    logic                  ctrl_a_switch;

    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_b;
    logic                  ctrl_rd_en_b;
    logic                  ctrl_b_accept_w;
    logic [$clog2(W)-1:0]  ctrl_b_weight_index;

    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_c;
    logic                  ctrl_rd_en_c;
    logic                  ctrl_c_valid;
    logic [2:0]            ctrl_vpu_mode;

    logic                  core_writeback_valid;
    logic [ADDR_WIDTH-1:0] ctrl_wr_addr_d;

    logic [W-1:0]          ctrl_row_mask;
    logic [W-1:0]          ctrl_col_mask;

    // ========================================================================
    // 2. DUT 实例化
    // ========================================================================
    control_unit #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .SYSTOLIC_ARRAY_WIDTH(SYSTOLIC_ARRAY_WIDTH)
    ) dut (
        .clk(clk),
        .rst(rst),
        .cmd_valid(cmd_valid),
        .cmd_data(cmd_data),
        .cmd_ready(cmd_ready),
        .busy(busy),
        .done_irq(done_irq),
        
        .ctrl_rd_addr_a(ctrl_rd_addr_a), .ctrl_rd_en_a(ctrl_rd_en_a),
        .ctrl_a_valid(ctrl_a_valid),     .ctrl_a_switch(ctrl_a_switch),
        
        .ctrl_rd_addr_b(ctrl_rd_addr_b), .ctrl_rd_en_b(ctrl_rd_en_b),
        .ctrl_b_accept_w(ctrl_b_accept_w), .ctrl_b_weight_index(ctrl_b_weight_index),
        
        .ctrl_rd_addr_c(ctrl_rd_addr_c), .ctrl_rd_en_c(ctrl_rd_en_c),
        .ctrl_c_valid(ctrl_c_valid),     .ctrl_vpu_mode(ctrl_vpu_mode),
        
        .core_writeback_valid(core_writeback_valid),
        .ctrl_wr_addr_d(ctrl_wr_addr_d),
        
        .ctrl_row_mask(ctrl_row_mask),
        .ctrl_col_mask(ctrl_col_mask)
    );

    // ========================================================================
    // 3. 辅助任务 (Helper Tasks)
    // ========================================================================
    
    // 时钟生成
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100MHz
    end

    // 任务: 发送指令
    task send_cmd(
        input [9:0] d_addr, 
        input [9:0] c_addr, 
        input [9:0] b_addr, 
        input [9:0] a_addr,
        input [7:0] val_n,
        input [7:0] val_k,
        input [7:0] val_m
    );
        // 等待 FIFO Ready
        wait(cmd_ready == 1);
        @(negedge clk);
        cmd_valid = 1;
        // Pack data: [63:54]D, [53:44]C, [43:34]B, [33:24]A, [23:16]N, [15:8]K, [7:0]M
        cmd_data = {d_addr, c_addr, b_addr, a_addr, val_n, val_k, val_m};
        @(negedge clk);
        cmd_valid = 0;
        $display("[Time %0t] Host sent Command: M=%0d, K=%0d, N=%0d", $time, val_m, val_k, val_n);
    endtask

    // 任务: 模拟 TPU Core 写回
    // 这是一个并行进程，需要等待一定时间后触发
    task sim_writeback_stream(input int rows_to_write);
        $display("[Time %0t] Mimic Core: Starting Writeback sequence for %0d rows...", $time, rows_to_write);
        repeat(rows_to_write) begin
            @(negedge clk);
            core_writeback_valid = 1;
        end
        @(negedge clk);
        core_writeback_valid = 0;
        $display("[Time %0t] Mimic Core: Writeback sequence done.", $time);
    endtask

    // ========================================================================
    // 4. 主测试流程
    // ========================================================================
    initial begin
        // --- 初始化 ---
        rst = 1;
        cmd_valid = 0;
        cmd_data = 0;
        core_writeback_valid = 0;
        
        #50;
        rst = 0;
        #20;
        
        $display("=== Test Start ===");

        // --- Scenario 1 & 2: Pipelining Test ---
        // 将指令发送逻辑合并，确保 FIFO 里提前有数据
        fork
            // 线程 1: 连续发送两条指令
            begin
                // Command 1 (16x16)
                send_cmd(10'd300, 10'd200, 10'd100, 10'd0, 8'd16, 8'd16, 8'd16);
                
                // [关键修改] 不要等待! 紧接着发送 Command 2
                // 只要 FIFO 没满，Host 就应该把任务塞进去。
                // 这样当 Hardware 完成 Task 1 的 B 阶段时，立刻就能在 FIFO 看到 Task 2
                send_cmd(10'd316, 10'd216, 10'd116, 10'd16, 8'd8, 8'd8, 8'd8);
            end
            
            // 线程 2: 监控 B-Flow (验证 Command 1)
            begin
                // ... (保持原有的 Task 1 B-Flow 检查代码不变) ...
                wait(ctrl_rd_en_b == 1);
                $display("[Time %0t] Task 1: B-Flow Started (Addr=%0d)", $time, ctrl_rd_addr_b);
                if (ctrl_rd_addr_b !== 100) $error("Error: B-Flow Base Address mismatch!");
                repeat(16) @(posedge clk);
                if (ctrl_rd_en_b == 0) $error("Error: B-Flow ended prematurely!");
                @(posedge clk); // Gap Cycle
                // 此时检查 Gap
                if (ctrl_rd_en_b == 1) $error("Error: B-Flow did not pause (Gap)!");
                else $display("[Time %0t] Task 1: B-Flow Completed & Gap detected.", $time);
            end
        join

        // --- Scenario 2 Check: Pipeline Overlap ---
        // 此时 Task 1 B 结束，Task 2 B 应该立即开始
        // 由于我们已经提前发送了指令，这里不需要再 send_cmd 了
        
        // 检查: 此时 ctrl_rd_en_b 应该再次变高 (Task 2 开始加载权重)
        // 同时 ctrl_rd_en_a 应该变高 (Task 1 开始输入数据)
        #1; // wait delta
        if (ctrl_rd_en_b && ctrl_rd_en_a) begin
            $display("[Time %0t] SUCCESS: Pipeline Overlap Detected!", $time);
            $display("           - Task 2 B-Flow loading from Addr %0d", ctrl_rd_addr_b);
            $display("           - Task 1 A-Flow streaming from Addr %0d", ctrl_rd_addr_a);
            $display("           - Switch Signal State: %b", ctrl_a_switch); // 应该是 1
        end else begin
            $error("Error: Pipeline overlap failed. B_en=%b, A_en=%b", ctrl_rd_en_b, ctrl_rd_en_a);
        end

        // 检查信号延迟对齐 (Task 1 A-Flow)
        // ctrl_rd_en_a 已经在上一个时钟沿拉高 (T=Cycle 17 start)
        // ctrl_a_valid 应该在下一个时钟沿拉高 (T=Cycle 18 start)
        @(posedge clk); 
        #1; // [新增] 等待信号稳定
        if (ctrl_a_valid == 1 && ctrl_rd_en_a == 1) 
            $display("[Time %0t] SUCCESS: A-Flow Valid Aligned (Delayed by 1 cycle)", $time);
        else 
            $error("Error: A-Flow Valid misalignment!");

        // 检查掩码动态变化
        // Task 1 的 K=16, 所以 Row Mask 应该是 FFFF
        if (ctrl_row_mask !== 16'hFFFF) $error("Error: Task 1 Row Mask incorrect! Got %h", ctrl_row_mask);

        // 等待 Task 1 A-Flow 结束 (16 cycles total, we are at cycle 2 of it)
        repeat(14) @(posedge clk);
        
        // Gap Cycle for A (Task 1)
        @(posedge clk); 
        // [删除/注释掉] 这行代码，因为无缝衔接时 Gap 消失了
        // if (ctrl_rd_en_a) $error("Error: A-Flow Gap missing");

        // [改为] 检查 Task 2 是否无缝接管
        #1;
        if (ctrl_rd_en_a == 1 && ctrl_rd_addr_a == 16) begin // Task 2 A-Base is 16
             $display("[Time %0t] SUCCESS: A-Flow Seamlessly Transformed to Task 2 (Addr=16)", $time);
        end else begin
             $error("Error: A-Flow did not transition to Task 2 correctly. En=%b, Addr=%d", ctrl_rd_en_a, ctrl_rd_addr_a);
        end

        // --- Scenario 3: Task 2 A-Flow Starts ---
        // 此时 Task 2 的 A-Flow 应该开始 (Task 1 A 结束后的下一拍)
        // Task 2 的 K=8, 所以 Row Mask 应该变为 00FF
        @(posedge clk);
        #1;
        if (ctrl_rd_en_a) begin
            $display("[Time %0t] Task 2 A-Flow Started.", $time);
            if (ctrl_row_mask === 16'h00FF) 
                $display("[Time %0t] SUCCESS: Row Mask updated dynamically for Task 2 (K=8 -> Mask=00FF)", $time);
            else 
                $error("Error: Row Mask did not update! Got %h", ctrl_row_mask);
        end

        // --- Scenario 4: Task 1 C-Flow (Bias) Check ---
        // 此时 Task 1 C-Flow 应该开始。C-Base 是 200
        if (ctrl_rd_en_c && ctrl_rd_addr_c === 200)
             $display("[Time %0t] Task 1 C-Flow Started Correctly (Addr=200)", $time);
        else
             // 如果这里报错，去波形图看 cnt_c 是否启动，以及地址是多少
             $error("Error: Task 1 C-Flow missing or wrong addr. En=%b, Addr=%d", ctrl_rd_en_c, ctrl_rd_addr_c);


        // --- Scenario 5: Writeback Simulation ---
        // 由于我们没有实例化 TPU Core，我们需要手动模拟 core_writeback_valid。
        // Task 1 (Full 16 rows) 预计在 C-Flow 结束时进入 D Queue。
        // Task 2 (8 rows) 随其后。
        
        // 等待一些时间让 Pipeline 跑一跑
        repeat(20) @(posedge clk);
        
        // 模拟 Task 1 的写回 (16 行)
        // 此时 Control Unit 应该已经把 Task 1 的信息推入 D Queue，并设置了 Col Mask = FFFF (N=16)
        // 我们检查 D Queue 是否准备好：ctrl_wr_addr_d 应该等于 Task 1 D Base (300)
        if (ctrl_wr_addr_d === 300) 
            $display("[Time %0t] D-Channel ready for Task 1 (Base=300). ColMask=%h", $time, ctrl_col_mask);
        else
            $warning("D-Channel Addr mismatch (Expected 300, Got %0d). Maybe timing diff.", ctrl_wr_addr_d);

        sim_writeback_stream(16);
        
        // 检查 Done IRQ
        @(posedge clk);
        if (done_irq) $display("[Time %0t] SUCCESS: Done IRQ received for Task 1", $time);
        else $error("Error: Done IRQ missing for Task 1");

        // 模拟 Task 2 的写回 (8 行)
        // Task 1 完成后，FSM 应该自动切换到 Task 2 的 D info (Base 316, N=8 -> Mask 00FF)
        @(posedge clk); // Wait for state switch
        #1;
        if (ctrl_wr_addr_d === 316) 
             $display("[Time %0t] D-Channel ready for Task 2 (Base=316). ColMask=%h", $time, ctrl_col_mask);
        
        if (ctrl_col_mask !== 16'h00FF) $error("Error: Col Mask did not update for Task 2 (N=8)");

        sim_writeback_stream(8); // Only 8 valid rows for Task 2

        @(posedge clk);
        if (done_irq) $display("[Time %0t] SUCCESS: Done IRQ received for Task 2", $time);

        // --- Final Check ---
        repeat(5) @(posedge clk);
        if (!busy) $display("[Time %0t] SUCCESS: Control Unit returned to IDLE.", $time);
        else $error("Error: Control Unit stuck in BUSY.");

        $display("=== Test End ===");
        $finish;
    end

    // 波形 Dump
    initial begin
        $dumpfile("control_unit.vcd");
        $dumpvars(0, tb_control_unit);
    end

endmodule
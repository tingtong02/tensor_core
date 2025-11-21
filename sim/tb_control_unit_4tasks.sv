`timescale 1ns/1ps

module tb_control_unit_4tasks;

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
    // 3. 辅助任务
    // ========================================================================
    
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100MHz
    end

    task send_cmd(
        input [9:0] d_addr, input [9:0] c_addr, input [9:0] b_addr, input [9:0] a_addr,
        input [7:0] val_n,  input [7:0] val_k,  input [7:0] val_m
    );
        if (cmd_ready == 0) begin
            $display("[Time %0t] FIFO FULL! Waiting...", $time);
            wait(cmd_ready == 1);
        end
        @(negedge clk);
        cmd_valid = 1;
        cmd_data = {d_addr, c_addr, b_addr, a_addr, val_n, val_k, val_m};
        @(negedge clk);
        cmd_valid = 0;
        $display("[Time %0t] Host sent CMD: M=%0d, K=%0d, N=%0d (D_Base=%0d)", $time, val_m, val_k, val_n, d_addr);
    endtask

    task sim_writeback_stream(input int rows_to_write);
        $display("[Time %0t] Core Mimic: Writing back %0d rows...", $time, rows_to_write);
        repeat(rows_to_write) begin
            @(negedge clk);
            core_writeback_valid = 1;
        end
        @(negedge clk);
        core_writeback_valid = 0;
    endtask

    // ========================================================================
    // 4. 主测试流程 (修正版)
    // ========================================================================
    initial begin
        // --- Init ---
        rst = 1; cmd_valid = 0; cmd_data = 0; core_writeback_valid = 0;
        #50; rst = 0; #20;
        
        $display("=== 4-Task Stress Test Start ===");

        // 使用 fork join 将所有操作并行化
        // 这样监控线程 (Pipeline Check) 从 T=0 就开始运行，不会错过任何信号
        fork
            // ------------------------------------------------------------
            // Thread 1: Burst Send 4 Commands
            // ------------------------------------------------------------
            begin
                // Task 1: 16x16
                send_cmd(10'd100, 10'd10, 10'd10, 10'd10, 8'd16, 8'd16, 8'd16);
                // Task 2: 8x8
                send_cmd(10'd200, 10'd20, 10'd20, 10'd20, 8'd8, 8'd8, 8'd8);
                // Task 3: 4x4
                send_cmd(10'd300, 10'd30, 10'd30, 10'd30, 8'd4, 8'd4, 8'd4);
                // Task 4: 16x16
                send_cmd(10'd400, 10'd40, 10'd40, 10'd40, 8'd16, 8'd16, 8'd16);
                
                $display("[Time %0t] All Commands Sent.", $time);
                
                // [修正] 移除 "FIFO FULL" 检查，因为硬件会实时消费指令
                // 或者改为检查 Busy 状态
                if (busy) $display("System is BUSY processing tasks (Expected).");
            end

            // ------------------------------------------------------------
            // Thread 2: Monitor Pipeline Transitions (B-Flow)
            // ------------------------------------------------------------
            begin
                // 1. Check Task 1 B Start (现在不会错过了)
                wait(ctrl_rd_en_b == 1 && ctrl_rd_addr_b == 10);
                $display("[Time %0t] Task 1 B Started.", $time);
                
                // Wait for Gap (Task 1 end)
                repeat(16) @(posedge clk);
                
                // 2. Check Task 1->2 Overlap
                @(posedge clk); // Transition Cycle
                #1;
                if (ctrl_rd_en_b == 1 && ctrl_rd_addr_b == 20)
                    $display("[Time %0t] SUCCESS: Overlap Task 1->2 (B Addr=20)", $time);
                else
                    $error("Failed Overlap 1->2. En=%b, Addr=%d", ctrl_rd_en_b, ctrl_rd_addr_b);

                // Wait for Task 2 B end
                repeat(16) @(posedge clk);
                
                // 3. Check Task 2->3 Overlap
                @(posedge clk);
                #1;
                if (ctrl_rd_en_b == 1 && ctrl_rd_addr_b == 30)
                    $display("[Time %0t] SUCCESS: Overlap Task 2->3 (B Addr=30)", $time);
                else
                    $error("Failed Overlap 2->3. En=%b, Addr=%d", ctrl_rd_en_b, ctrl_rd_addr_b);

                // Wait for Task 3 B end
                repeat(16) @(posedge clk);

                // 4. Check Task 3->4 Overlap
                @(posedge clk);
                #1;
                if (ctrl_rd_en_b == 1 && ctrl_rd_addr_b == 40)
                    $display("[Time %0t] SUCCESS: Overlap Task 3->4 (B Addr=40)", $time);
                else
                    $error("Failed Overlap 3->4. En=%b, Addr=%d", ctrl_rd_en_b, ctrl_rd_addr_b);
            end

            // ------------------------------------------------------------
            // Thread 3: Writeback Mimic
            // ------------------------------------------------------------
            begin
                // Wait for Task 1 (16 rows)
                wait(ctrl_wr_addr_d == 100); // Base 100
                @(posedge clk); 
                if (ctrl_col_mask !== 16'hFFFF) $error("Task 1 ColMask mismatch! %h", ctrl_col_mask);
                sim_writeback_stream(16);
                wait(done_irq); @(posedge clk);

                // Wait for Task 2 (8 rows)
                wait(ctrl_wr_addr_d == 200); // Base 200
                @(posedge clk);
                if (ctrl_col_mask !== 16'h00FF) $error("Task 2 ColMask mismatch! %h", ctrl_col_mask);
                sim_writeback_stream(8); 
                wait(done_irq); @(posedge clk);

                // Wait for Task 3 (4 rows)
                wait(ctrl_wr_addr_d == 300); // Base 300
                @(posedge clk);
                if (ctrl_col_mask !== 16'h000F) $error("Task 3 ColMask mismatch! %h", ctrl_col_mask);
                sim_writeback_stream(4); 
                wait(done_irq); @(posedge clk);

                // Wait for Task 4 (16 rows)
                wait(ctrl_wr_addr_d == 400); // Base 400
                @(posedge clk);
                if (ctrl_col_mask !== 16'hFFFF) $error("Task 4 ColMask mismatch! %h", ctrl_col_mask);
                sim_writeback_stream(16);
                wait(done_irq); @(posedge clk);
                
                $display("[Time %0t] SUCCESS: All 4 Writebacks Completed.", $time);
            end
        join

        // Final Check
        repeat(20) @(posedge clk);
        if (busy == 0) 
            $display("[Time %0t] SUCCESS: Test Finished, CU IDLE.", $time);
        else
            $error("CU Stuck Busy!");
        
        $finish;
    end

endmodule
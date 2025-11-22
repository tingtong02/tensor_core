`timescale 1ns/1ps

module tb_control_unit;

    // ========================================================================
    // 1. 参数与信号定义
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

    // Stage A
    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_a;
    logic                  ctrl_rd_en_a;
    logic                  ctrl_a_valid;
    logic                  ctrl_a_switch;

    // Stage B
    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_b;
    logic                  ctrl_rd_en_b;
    logic                  ctrl_b_accept_w;
    logic [$clog2(W)-1:0]  ctrl_b_weight_index;

    // Stage C
    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_c;
    logic                  ctrl_rd_en_c;
    logic                  ctrl_c_valid;
    logic [2:0]            ctrl_vpu_mode;

    // Stage D
    logic                  core_writeback_valid;
    logic [ADDR_WIDTH-1:0] ctrl_wr_addr_d;

    // Masks
    logic [W-1:0] ctrl_row_mask;
    logic [W-1:0] ctrl_col_mask;

    // 辅助结构体
    typedef struct packed {
        logic [ADDR_WIDTH-1:0] addr_d;
        logic [ADDR_WIDTH-1:0] addr_c;
        logic [ADDR_WIDTH-1:0] addr_b;
        logic [ADDR_WIDTH-1:0] addr_a;
        logic [7:0]            len_n;
        logic [7:0]            len_k;
        logic [7:0]            len_m;
    } command_t;

    // ========================================================================
    // 2. 模块实例化 (DUT)
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
        
        .ctrl_row_mask(ctrl_row_mask), .ctrl_col_mask(ctrl_col_mask)
    );

    // ========================================================================
    // 3. 时钟生成
    // ========================================================================
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 10ns Period, 100MHz
    end

    // ========================================================================
    // 4. 模拟 D 阶段 (Writeback) 的行为
    // ========================================================================
    int wb_trigger_cnt = 0;
    
    always @(negedge ctrl_c_valid) begin
        if (!rst) begin
            wb_trigger_cnt++;
        end
    end

    initial begin
        core_writeback_valid = 0;
        forever begin
            wait(wb_trigger_cnt > 0);
            
            // 模拟阵列计算延迟
            repeat(20) @(posedge clk);
            
            // 发送写回有效信号
            repeat(W) begin
                @(posedge clk);
                core_writeback_valid <= 1;
            end
            @(posedge clk);
            core_writeback_valid <= 0;
            
            wb_trigger_cnt--;
        end
    end

    // ========================================================================
    // 5. 智能监控器：基于队列的时间戳检查
    // ========================================================================
    
    realtime b_start_queue[$]; 
    realtime a_start_queue[$]; 

    // --- Monitor Stage B ---
    always @(posedge ctrl_rd_en_b) begin
        b_start_queue.push_back($realtime);
        $display("\n[%0t] >>> Stage B (Weight) Started", $time);
    end

    // --- Monitor Stage A ---
    always @(posedge ctrl_rd_en_a) begin
        realtime t_start_b;
        realtime t_start_a;
        longint diff_cnt_b_a;

        t_start_a = $realtime;
        a_start_queue.push_back(t_start_a);

        if (b_start_queue.size() > 0) begin
            t_start_b = b_start_queue.pop_front();
            diff_cnt_b_a = (t_start_a - t_start_b) / 10.0;
            
            $display("[%0t] >>> Stage A (Input)  Started. Delta from B = %0d cycles (Expected 17)", $time, diff_cnt_b_a);
            
            if (diff_cnt_b_a == 17) 
                $display("        [PASS] Timing Check B->A");
            else 
                $error("        [FAIL] Timing Check B->A. Expected 17, Got %0d", diff_cnt_b_a);
        end else begin
            $error("        [FAIL] Stage A started but no corresponding Stage B start time found!");
        end
    end

    // --- Monitor Stage C ---
    always @(posedge ctrl_rd_en_c) begin
        realtime t_start_a;
        realtime t_start_c;
        longint diff_cnt_a_c;

        t_start_c = $realtime;
        
        if (a_start_queue.size() > 0) begin
            t_start_a = a_start_queue.pop_front();
            diff_cnt_a_c = (t_start_c - t_start_a) / 10.0; 
            
            // [修改点] 期望值改为 17 (因为 RTL 改为 cnt_a == W-1 触发)
            $display("[%0t] >>> Stage C (Bias)   Started. Delta from A = %0d cycles (Expected 17)", $time, diff_cnt_a_c);
            
            if (diff_cnt_a_c == 17) 
                $display("        [PASS] Timing Check A->C (Serial)");
            else 
                $error("        [FAIL] Timing Check A->C. Expected 17, Got %0d", diff_cnt_a_c);
        end else begin
            $error("        [FAIL] Stage C started but no corresponding Stage A start time found!");
        end
    end

    // ========================================================================
    // 6. 主测试流程
    // ========================================================================
    task send_cmd(input logic [9:0] ad, ac, ab, aa);
        command_t cmd;
        cmd.addr_d = ad;
        cmd.addr_c = ac;
        cmd.addr_b = ab;
        cmd.addr_a = aa;
        cmd.len_n  = 8'd8; 
        cmd.len_k  = 8'd8;
        cmd.len_m  = 8'd8;
        
        wait(!rst && cmd_ready);
        @(posedge clk);
        cmd_valid <= 1;
        cmd_data  <= cmd;
        @(posedge clk);
        cmd_valid <= 0;
        $display("[%0t] [Host] Command Sent.", $time);
    endtask

    initial begin
        // 初始化
        rst = 1;
        cmd_valid = 0;
        cmd_data = 0;
        
        // 复位
        repeat(10) @(posedge clk);
        rst = 0;
        $display("[%0t] Reset released.", $time);
        repeat(5) @(posedge clk);

        // --- Test Case 1: Single Command ---
        $display("========================================");
        $display(" Test Case 1: Single Command");
        $display("========================================");
        send_cmd(10'h100, 10'h200, 10'h300, 10'h400);
        
        // 等待中断
        wait(done_irq);
        @(posedge clk);
        $display("[%0t] [IRQ] Task 1 Done!", $time);
        
        repeat(20) @(posedge clk);

        // --- Test Case 2: Multiple Commands (Back-to-Back) ---
        $display("\n========================================");
        $display(" Test Case 2: Multiple Commands (Back-to-Back)");
        $display("========================================");
        
        fork
            begin
                send_cmd(10'h101, 10'h201, 10'h301, 10'h401);
                send_cmd(10'h102, 10'h202, 10'h302, 10'h402);
            end
        join

        wait(done_irq);
        @(posedge clk); 
        wait(!done_irq);
        $display("[%0t] [IRQ] Task 2-1 Done!", $time);
        
        wait(done_irq);
        @(posedge clk);
        $display("[%0t] [IRQ] Task 2-2 Done!", $time);

        repeat(20) @(posedge clk);
        $display("\nAll Tests Completed Successfully.");
        $finish;
    end

endmodule
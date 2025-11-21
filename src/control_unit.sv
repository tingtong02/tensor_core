`timescale 1ns/1ps
`default_nettype none

module control_unit #(
    parameter int ADDR_WIDTH           = 10,
    parameter int SYSTOLIC_ARRAY_WIDTH = 16
)(
    input logic clk,
    input logic rst,

    // --- 1. Host Command Interface ---
    input logic        cmd_valid,
    input logic [63:0] cmd_data,
    output logic       cmd_ready, 
    
    output logic       busy,      
    output logic       done_irq,  

    // --- 2. TPU Core Control Interfaces ---
    output logic [ADDR_WIDTH-1:0] ctrl_rd_addr_a,
    output logic                  ctrl_rd_en_a,
    output logic                  ctrl_a_valid,  
    output logic                  ctrl_a_switch, 
    
    output logic [ADDR_WIDTH-1:0] ctrl_rd_addr_b,
    output logic                  ctrl_rd_en_b,
    output logic                  ctrl_b_accept_w, 
    output logic [$clog2(SYSTOLIC_ARRAY_WIDTH)-1:0] ctrl_b_weight_index, 

    output logic [ADDR_WIDTH-1:0] ctrl_rd_addr_c,
    output logic                  ctrl_rd_en_c,
    output logic                  ctrl_c_valid,    
    output logic [2:0]            ctrl_vpu_mode,   

    input logic                   core_writeback_valid,
    output logic [ADDR_WIDTH-1:0] ctrl_wr_addr_d,

    output logic [SYSTOLIC_ARRAY_WIDTH-1:0] ctrl_row_mask,
    output logic [SYSTOLIC_ARRAY_WIDTH-1:0] ctrl_col_mask
);

    localparam W = SYSTOLIC_ARRAY_WIDTH; // 16

    // ========================================================================
    // 结构定义
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

    // ========================================================================
    // FIFO 逻辑 (保持不变)
    // ========================================================================
    logic       fifo_empty;
    logic       fifo_rd_en;
    command_t   fifo_dout;
    logic       fifo_full;
    logic [63:0] mem_fifo [4];
    logic [1:0]  wr_ptr, rd_ptr;
    logic [2:0]  fifo_count;

    assign cmd_ready = !fifo_full;
    assign fifo_full = (fifo_count == 3'd4);
    assign fifo_empty = (fifo_count == 3'd0);
    assign fifo_dout  = command_t'(mem_fifo[rd_ptr]); 

    always_ff @(posedge clk) begin
        if (rst) begin
            wr_ptr <= 0; rd_ptr <= 0; fifo_count <= 0;
        end else begin
            if (cmd_valid && !fifo_full) begin
                mem_fifo[wr_ptr] <= cmd_data;
                wr_ptr <= wr_ptr + 1'b1;
            end
            if (fifo_rd_en && !fifo_empty) begin
                rd_ptr <= rd_ptr + 1'b1;
            end
            case ({cmd_valid && !fifo_full, fifo_rd_en && !fifo_empty})
                2'b10: fifo_count <= fifo_count + 1'b1;
                2'b01: fifo_count <= fifo_count - 1'b1;
                default: fifo_count <= fifo_count;
            endcase
        end
    end

    // ========================================================================
    // 级联触发信号
    // ========================================================================
    logic       trigger_a_start;
    command_t   cmd_info_for_a; 
    
    logic       trigger_c_start;
    command_t   cmd_info_for_c;

    logic       trigger_d_queue; 
    command_t   cmd_info_for_d;

    assign busy = !fifo_empty; 

    // ========================================================================
    // Stage B (Master) - 权重加载
    // ========================================================================
    // 计数范围: 0..15 (Work), 16 (Gap/Decision)
    // 绝不进入 17
    
    logic [4:0] cnt_b; 
    logic       b_active;
    command_t   curr_cmd_b;

    always_ff @(posedge clk) begin
        if (rst) begin
            cnt_b <= 0; b_active <= 0; fifo_rd_en <= 0;
            ctrl_rd_en_b <= 0; ctrl_rd_addr_b <= 0;
            trigger_a_start <= 0;
        end else begin
            // 默认复位单周期脉冲信号
            fifo_rd_en <= 0;
            trigger_a_start <= 0;

            if (!b_active) begin
                // --- IDLE 状态 ---
                if (!fifo_empty) begin
                    fifo_rd_en <= 1; // Pop FIFO
                    b_active   <= 1;
                    cnt_b      <= 0; // 下一拍直接开始 Cycle 0
                end else begin
                    ctrl_rd_en_b <= 0;
                end
            end else begin
                // --- ACTIVE 状态 ---
                
                // 1. 读使能逻辑
                if (cnt_b == 0) begin
                    // 刚从 IDLE 进来，或者刚 Loop 回来
                    curr_cmd_b <= fifo_dout; // 锁存指令
                    ctrl_rd_en_b   <= 1'b1;
                    ctrl_rd_addr_b <= fifo_dout.addr_b; 
                end 
                else if (cnt_b < W) begin // 1..15
                    ctrl_rd_en_b   <= 1'b1;
                    ctrl_rd_addr_b <= curr_cmd_b.addr_b + ADDR_WIDTH'(cnt_b);
                end 
                else begin // cnt_b == 16 (Gap)
                    ctrl_rd_en_b <= 1'b0;
                end

                // 2. 计数器流转与决策逻辑 (关键修复)
                if (cnt_b < W) begin
                    // 0..15 -> 自增
                    cnt_b <= cnt_b + 1'b1;
                end 
                else begin 
                    // cnt_b == 16 (Gap 周期结束)
                    // 此时必须决定: 是 Loop 回 0，还是回 IDLE
                    
                    // 无论如何，都要触发下一级 (A)
                    trigger_a_start <= 1'b1;
                    cmd_info_for_a  <= curr_cmd_b;
                    
                    if (!fifo_empty) begin
                        // 有新指令 -> Loop
                        fifo_rd_en <= 1;
                        cnt_b      <= 0; // 直接回 0
                        // b_active 保持 1
                    end else begin
                        // 无指令 -> IDLE
                        b_active <= 0;
                        cnt_b    <= 0; // Reset
                    end
                end
            end
        end
    end

    // B-Core Control Generation
    always_ff @(posedge clk) begin
        if (rst) begin
            ctrl_b_accept_w <= 0; ctrl_b_weight_index <= 0;
        end else begin
            ctrl_b_accept_w <= ctrl_rd_en_b;
            if (ctrl_rd_en_b) begin
                if (cnt_b == 0) 
                     ctrl_b_weight_index <= ($clog2(W))'(W - 1); 
                else 
                     ctrl_b_weight_index <= ctrl_b_weight_index - 1'b1;
            end
        end
    end

    // ========================================================================
    // Stage A (Input) & Switch - Follower 1
    // ========================================================================
    
    logic [4:0] cnt_a;
    logic       a_active;
    command_t   curr_cmd_a;

    always_ff @(posedge clk) begin
        if (rst) begin
            cnt_a <= 0; a_active <= 0; 
            ctrl_rd_en_a <= 0; ctrl_rd_addr_a <= 0;
            ctrl_a_switch <= 0;
            trigger_c_start <= 0;
        end else begin
            ctrl_a_switch <= 0;
            trigger_c_start <= 0;

            if (!a_active) begin
                if (trigger_a_start) begin
                    a_active <= 1;
                    cnt_a <= 0;
                    curr_cmd_a <= cmd_info_for_a;
                    
                    ctrl_a_switch  <= 1'b1; // Start Pulse
                    ctrl_rd_en_a   <= 1'b1;
                    ctrl_rd_addr_a <= cmd_info_for_a.addr_a;
                end else begin
                    ctrl_rd_en_a <= 0;
                end
            end else begin
                // Logic
                if (cnt_a < W - 1) begin // 0..14 (next is 1..15)
                    ctrl_rd_en_a   <= 1'b1;
                    ctrl_rd_addr_a <= ctrl_rd_addr_a + 1'b1;
                end else begin // 15 & 16
                    ctrl_rd_en_a <= 1'b0;
                end

                // Counter & Decision
                if (cnt_a < W) begin
                    cnt_a <= cnt_a + 1'b1;
                end else begin
                    // cnt_a == 16 (Gap Done)
                    trigger_c_start <= 1'b1;
                    cmd_info_for_c  <= curr_cmd_a;
                    
                    if (trigger_a_start) begin
                        // Pipeline Overlap: 收到上级的新触发
                        cnt_a <= 0;
                        curr_cmd_a <= cmd_info_for_a;
                        
                        ctrl_a_switch  <= 1'b1; // New Start Pulse
                        ctrl_rd_en_a   <= 1'b1;
                        ctrl_rd_addr_a <= cmd_info_for_a.addr_a;
                    end else begin
                        a_active <= 0;
                        cnt_a    <= 0;
                    end
                end
            end
        end
    end

    // A Valid Generation
    always_ff @(posedge clk) begin
        if (rst) ctrl_a_valid <= 0;
        else ctrl_a_valid <= ctrl_rd_en_a;
    end

    // ========================================================================
    // Stage C (Bias) - Follower 2
    // ========================================================================
    
    logic [4:0] cnt_c;
    logic       c_active;
    command_t   curr_cmd_c;

    always_ff @(posedge clk) begin
        if (rst) begin
            cnt_c <= 0; c_active <= 0;
            ctrl_rd_en_c <= 0; ctrl_rd_addr_c <= 0;
            trigger_d_queue <= 0;
        end else begin
            trigger_d_queue <= 0;

            if (!c_active) begin
                if (trigger_c_start) begin
                    c_active <= 1;
                    cnt_c <= 0;
                    curr_cmd_c <= cmd_info_for_c;
                    
                    ctrl_rd_en_c   <= 1'b1;
                    ctrl_rd_addr_c <= cmd_info_for_c.addr_c;
                end else begin
                    ctrl_rd_en_c <= 0;
                end
            end else begin
                // Logic
                if (cnt_c < W - 1) begin
                    ctrl_rd_en_c   <= 1'b1;
                    ctrl_rd_addr_c <= ctrl_rd_addr_c + 1'b1;
                end else begin
                    ctrl_rd_en_c <= 1'b0;
                end

                // Counter & Decision
                if (cnt_c < W) begin
                    cnt_c <= cnt_c + 1'b1;
                end else begin
                    // cnt_c == 16
                    trigger_d_queue <= 1'b1;
                    cmd_info_for_d  <= curr_cmd_c;

                    if (trigger_c_start) begin
                        cnt_c <= 0;
                        curr_cmd_c <= cmd_info_for_c;
                        
                        ctrl_rd_en_c   <= 1'b1;
                        ctrl_rd_addr_c <= cmd_info_for_c.addr_c;
                    end else begin
                        c_active <= 0;
                        cnt_c    <= 0;
                    end
                end
            end
        end
    end

    // C Valid Generation
    always_ff @(posedge clk) begin
        if (rst) ctrl_c_valid <= 0;
        else ctrl_c_valid <= ctrl_rd_en_c;
    end
    
    assign ctrl_vpu_mode = 3'b001; 

    // ========================================================================
    // Stage D (Writeback)
    // ========================================================================
    
    typedef struct packed {
        logic [ADDR_WIDTH-1:0] addr_d;
        logic [7:0]            len_m;
        logic [7:0]            len_n;
        logic [7:0]            len_k;
    } d_info_t;

    d_info_t d_queue [4];
    logic [1:0] dq_wr, dq_rd;
    logic [2:0] dq_cnt;
    logic       d_task_active;
    logic       d_task_done;
    d_info_t    curr_d_info;
    logic [7:0] wb_row_cnt;

    assign done_irq = d_task_done;

    // Queue Manage
    always_ff @(posedge clk) begin
        if (rst) begin
            dq_wr <= 0; dq_cnt <= 0;
        end else begin
            if (trigger_d_queue) begin
                d_queue[dq_wr].addr_d <= cmd_info_for_d.addr_d;
                d_queue[dq_wr].len_m  <= cmd_info_for_d.len_m;
                d_queue[dq_wr].len_n  <= cmd_info_for_d.len_n;
                d_queue[dq_wr].len_k  <= cmd_info_for_d.len_k;
                dq_wr <= dq_wr + 1'b1;
                dq_cnt <= dq_cnt + 1'b1; 
            end else if (d_task_done) begin
                dq_cnt <= dq_cnt - 1'b1;
            end
        end
    end

    // WB Logic
    always_ff @(posedge clk) begin
        if (rst) begin
            dq_rd <= 0; d_task_active <= 0; wb_row_cnt <= 0; d_task_done <= 0;
            ctrl_wr_addr_d <= 0;
        end else begin
            d_task_done <= 0;

            if (!d_task_active) begin
                if (dq_cnt > 0) begin
                    curr_d_info <= d_queue[dq_rd];
                    dq_rd <= dq_rd + 1'b1;
                    d_task_active <= 1;
                    wb_row_cnt <= 0;
                    ctrl_wr_addr_d <= d_queue[dq_rd].addr_d; 
                end
            end else begin
                if (core_writeback_valid) begin
                    wb_row_cnt <= wb_row_cnt + 1'b1;
                    ctrl_wr_addr_d <= ctrl_wr_addr_d + 1'b1; 
                    
                    // 始终等待16行，因为 Array 总是吐出 16 行数据
                    if (wb_row_cnt == (W - 1)) begin
                        d_task_done <= 1; 
                        d_task_active <= 0; 
                    end
                end
            end
        end
    end

    // Mask Generation
    always_comb begin
        ctrl_row_mask = '0;
        ctrl_col_mask = '0;
        
        for (int i = 0; i < W; i++) begin
            if (i < curr_cmd_a.len_k) ctrl_row_mask[i] = 1'b1;
        end
        if (!a_active) ctrl_row_mask = '0; 

        for (int i = 0; i < W; i++) begin
            if (i < curr_d_info.len_n) ctrl_col_mask[i] = 1'b1;
        end
         if (!d_task_active) ctrl_col_mask = '0;
    end

endmodule
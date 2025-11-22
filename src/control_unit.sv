`timescale 1ns/1ps
`default_nettype none

module control_unit #(
    parameter int ADDR_WIDTH           = 10,
    parameter int SYSTOLIC_ARRAY_WIDTH = 16
)(
    input logic clk,
    input logic rst,

    // Host Interface
    input logic        cmd_valid,
    input logic [63:0] cmd_data,
    output logic       cmd_ready, 
    output logic       busy,      
    output logic       done_irq,  

    // Core Interface
    output logic [ADDR_WIDTH-1:0] ctrl_rd_addr_a, output logic ctrl_rd_en_a, output logic ctrl_a_valid, output logic ctrl_a_switch, 
    output logic [ADDR_WIDTH-1:0] ctrl_rd_addr_b, output logic ctrl_rd_en_b, output logic ctrl_b_accept_w, output logic [$clog2(SYSTOLIC_ARRAY_WIDTH)-1:0] ctrl_b_weight_index, 
    output logic [ADDR_WIDTH-1:0] ctrl_rd_addr_c, output logic ctrl_rd_en_c, output logic ctrl_c_valid, output logic [2:0] ctrl_vpu_mode,   

    input logic                   core_writeback_valid,
    output logic [ADDR_WIDTH-1:0] ctrl_wr_addr_d,
    output logic [SYSTOLIC_ARRAY_WIDTH-1:0] ctrl_row_mask,
    output logic [SYSTOLIC_ARRAY_WIDTH-1:0] ctrl_col_mask
);

    localparam W = SYSTOLIC_ARRAY_WIDTH;

    // --- FIFO & Command Struct ---
    typedef struct packed {
        logic [ADDR_WIDTH-1:0] addr_d, addr_c, addr_b, addr_a;
        logic [7:0]            len_n, len_k, len_m;
    } command_t;

    logic       fifo_empty, fifo_rd_en, fifo_full;
    command_t   fifo_dout;
    logic [63:0] mem_fifo [4];
    logic [1:0]  wr_ptr, rd_ptr;
    logic [2:0]  fifo_count;

    logic       trigger_a_start, trigger_c_start, trigger_d_queue;
    command_t   cmd_info_for_a, cmd_info_for_c, cmd_info_for_d;

    // 活跃参数锁存器 (用于生成 Mask)
    logic [7:0] active_len_k;
    logic [7:0] active_len_n;

    assign cmd_ready = !fifo_full;
    assign fifo_full = (fifo_count == 3'd4);
    assign fifo_empty = (fifo_count == 3'd0);
    assign fifo_dout  = command_t'(mem_fifo[rd_ptr]);
    
    // Busy 逻辑: 只要有任务在排队，或任意流水线阶段活跃
    // 注意: 需要包含所有 active 信号和 dq_cnt
    // 这里为了简化，我们在 mask 逻辑里单独判断，busy 输出给 host 可以简单点
    assign busy = !fifo_empty || b_active || a_active || c_active || d_task_active || (dq_cnt != 0);

    // --- FIFO Logic ---
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

    // --- [关键新增] 参数锁存逻辑 ---
    // 当从 FIFO 取出一个新任务时，更新当前的 K 和 N
    // 基于假设: 连续任务的 K, N 是一致的。
    always_ff @(posedge clk) begin
        if (rst) begin
            active_len_k <= 0;
            active_len_n <= 0;
        end else if (fifo_rd_en) begin
            // fifo_dout 在 fifo_rd_en 有效的当拍是旧值，下一拍才是新值？
            // 不，这是同步 RAM。如果 fifo_rd_en 是组合逻辑生成的（见 Stage B），
            // 这里的 fifo_dout 是 mem_fifo[rd_ptr]。
            // rd_ptr 在这一拍还没变。所以这里取到的是当前要执行的任务参数。正确。
            active_len_k <= fifo_dout.len_k;
            active_len_n <= fifo_dout.len_n;
        end
    end

    // --- Stage B (Master) ---
    logic [4:0] cnt_b;
    logic       b_active;
    command_t   curr_cmd_b;

    always_ff @(posedge clk) begin
        if (rst) begin
            cnt_b <= 0; b_active <= 0; fifo_rd_en <= 0;
            ctrl_rd_en_b <= 0; ctrl_rd_addr_b <= 0; trigger_a_start <= 0;
        end else begin
            fifo_rd_en <= 0; trigger_a_start <= 0;
            if (!b_active) begin
                if (!fifo_empty) begin 
                    fifo_rd_en <= 1; // Pop 指令，同时触发 active_len 更新
                    b_active <= 1; cnt_b <= 0; 
                end else ctrl_rd_en_b <= 0;
            end else begin
                if (cnt_b == 0) begin
                    curr_cmd_b <= fifo_dout; ctrl_rd_en_b <= 1'b1; ctrl_rd_addr_b <= fifo_dout.addr_b;
                end else if (cnt_b < W) begin
                    ctrl_rd_en_b <= 1'b1; ctrl_rd_addr_b <= curr_cmd_b.addr_b + ADDR_WIDTH'(cnt_b);
                end else begin
                    ctrl_rd_en_b <= 1'b0; trigger_a_start <= 1'b1; cmd_info_for_a <= curr_cmd_b;
                    if (!fifo_empty) begin fifo_rd_en <= 1; cnt_b <= 0; end
                    else begin b_active <= 0; cnt_b <= 0; end
                end
                if (cnt_b < W) cnt_b <= cnt_b + 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin ctrl_b_accept_w <= 0; ctrl_b_weight_index <= 0; end
        else begin
            ctrl_b_accept_w <= ctrl_rd_en_b;
            if (ctrl_rd_en_b) begin
                if (cnt_b == 0) ctrl_b_weight_index <= ($clog2(W))'(W - 1);
                else ctrl_b_weight_index <= ctrl_b_weight_index - 1'b1;
            end
        end
    end

    // --- Stage A (Input) ---
    logic [4:0] cnt_a;
    logic       a_active;
    command_t   curr_cmd_a;

    always_ff @(posedge clk) begin
        if (rst) begin
            cnt_a <= 0; a_active <= 0; ctrl_rd_en_a <= 0; ctrl_rd_addr_a <= 0;
            ctrl_a_switch <= 0; trigger_c_start <= 0;
        end else begin
            ctrl_a_switch <= 0; trigger_c_start <= 0;
            if (!a_active) begin
                if (trigger_a_start) begin
                    a_active <= 1; cnt_a <= 0; curr_cmd_a <= cmd_info_for_a;
                    ctrl_a_switch <= 1'b1; ctrl_rd_en_a <= 1'b1; ctrl_rd_addr_a <= cmd_info_for_a.addr_a;
                end else ctrl_rd_en_a <= 0;
            end else begin
                if (cnt_a < W - 1) begin
                    ctrl_rd_en_a <= 1'b1; ctrl_rd_addr_a <= ctrl_rd_addr_a + 1'b1;
                end else ctrl_rd_en_a <= 1'b0;

                if (cnt_a < W) begin
                    cnt_a <= cnt_a + 1'b1;
                    // [保持 W-1 (15)] 确保 Bias 对齐
                    if (cnt_a == W - 1) begin
                        trigger_c_start <= 1'b1; cmd_info_for_c <= curr_cmd_a;
                    end
                end else begin
                    if (trigger_a_start) begin
                        cnt_a <= 0; curr_cmd_a <= cmd_info_for_a;
                        ctrl_a_switch <= 1'b1; ctrl_rd_en_a <= 1'b1; ctrl_rd_addr_a <= cmd_info_for_a.addr_a;
                    end else begin
                        a_active <= 0; cnt_a <= 0;
                    end
                end
            end
        end
    end
    always_ff @(posedge clk) if(rst) ctrl_a_valid<=0; else ctrl_a_valid<=ctrl_rd_en_a;

    // --- Stage C (Bias) ---
    logic [4:0] cnt_c;
    logic       c_active;
    command_t   curr_cmd_c;

    always_ff @(posedge clk) begin
        if (rst) begin
            cnt_c <= 0; c_active <= 0; ctrl_rd_en_c <= 0; ctrl_rd_addr_c <= 0; trigger_d_queue <= 0;
        end else begin
            trigger_d_queue <= 0;
            if (!c_active) begin
                if (trigger_c_start) begin
                    c_active <= 1; cnt_c <= 0; curr_cmd_c <= cmd_info_for_c;
                    ctrl_rd_en_c <= 1'b1; ctrl_rd_addr_c <= cmd_info_for_c.addr_c;
                end else ctrl_rd_en_c <= 0;
            end else begin
                if (cnt_c < W - 1) begin
                    ctrl_rd_en_c <= 1'b1; ctrl_rd_addr_c <= ctrl_rd_addr_c + 1'b1;
                end else ctrl_rd_en_c <= 1'b0;

                if (cnt_c < W) begin
                    cnt_c <= cnt_c + 1'b1;
                end else begin
                    trigger_d_queue <= 1'b1; cmd_info_for_d <= curr_cmd_c;
                    if (trigger_c_start) begin
                        cnt_c <= 0; curr_cmd_c <= cmd_info_for_c;
                        ctrl_rd_en_c <= 1'b1; ctrl_rd_addr_c <= cmd_info_for_c.addr_c;
                    end else begin
                        c_active <= 0; cnt_c <= 0;
                    end
                end
            end
        end
    end
    always_ff @(posedge clk) if(rst) ctrl_c_valid<=0; else ctrl_c_valid<=ctrl_rd_en_c;
    assign ctrl_vpu_mode = 3'b001;

    // --- Stage D (Writeback) ---
    typedef struct packed {
        logic [ADDR_WIDTH-1:0] addr_d;
        logic [7:0] len_m, len_n, len_k;
    } d_info_t;

    d_info_t d_queue [4];
    logic [1:0] dq_wr, dq_rd;
    logic [2:0] dq_cnt;
    logic       d_task_active, d_task_done;
    d_info_t    curr_d_info;
    logic [7:0] wb_row_cnt;

    assign done_irq = d_task_done;

    always_ff @(posedge clk) begin
        if (rst) begin dq_wr <= 0; dq_cnt <= 0; end
        else if (trigger_d_queue) begin
            d_queue[dq_wr].addr_d <= cmd_info_for_d.addr_d;
            d_queue[dq_wr].len_m <= cmd_info_for_d.len_m;
            d_queue[dq_wr].len_n <= cmd_info_for_d.len_n;
            d_queue[dq_wr].len_k <= cmd_info_for_d.len_k;
            dq_wr <= dq_wr + 1'b1; dq_cnt <= dq_cnt + 1'b1;
        end else if (d_task_done) dq_cnt <= dq_cnt - 1'b1;
    end

    always_ff @(posedge clk) begin
        if (rst) begin dq_rd <= 0; d_task_active <= 0; wb_row_cnt <= 0; d_task_done <= 0; ctrl_wr_addr_d <= 0; end
        else begin
            d_task_done <= 0;
            if (!d_task_active) begin
                if (dq_cnt > 0) begin
                    curr_d_info <= d_queue[dq_rd]; dq_rd <= dq_rd + 1'b1;
                    d_task_active <= 1; wb_row_cnt <= 0; ctrl_wr_addr_d <= d_queue[dq_rd].addr_d;
                end
            end else if (core_writeback_valid) begin
                wb_row_cnt <= wb_row_cnt + 1'b1;
                ctrl_wr_addr_d <= ctrl_wr_addr_d + 1'b1;
                if (wb_row_cnt == (W - 1)) begin
                    d_task_done <= 1; d_task_active <= 0;
                end
            end
        end
    end

    // --- Mask Generation (修正版) ---
    // 1. 使用 busy 信号判断系统是否忙碌
    // 2. 使用锁存的 active_len_k/n 生成精确掩码
    always_comb begin
        ctrl_row_mask = '0;
        ctrl_col_mask = '0;
        
        // 只要有活干 (Busy)
        if (busy) begin 
             // 生成精确掩码
             for (int i = 0; i < W; i++) begin
                if (i < active_len_k) ctrl_row_mask[i] = 1'b1;
                if (i < active_len_n) ctrl_col_mask[i] = 1'b1;
             end
        end
    end

endmodule
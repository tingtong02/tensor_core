`timescale 1ns/1ps
`default_nettype none

module control_unit #(
    parameter int ADDR_WIDTH           = 10,
    parameter int SYSTOLIC_ARRAY_WIDTH = 16
)(
    input logic clk,
    input logic rst,

    // --- 1. 主机命令接口 ---
    input logic        cmd_valid,
    input logic [63:0] cmd_data,
    output logic       cmd_ready, 
    
    output logic       busy,      
    output logic       done_irq,  

    // --- 2. TPU 核心控制接口 ---
    
    // Stage A (Input Activations)
    output logic [ADDR_WIDTH-1:0] ctrl_rd_addr_a,
    output logic                  ctrl_rd_en_a,
    output logic                  ctrl_a_valid,  
    output logic                  ctrl_a_switch,
    output logic                  ctrl_psum_valid, // Psum Valid (Top Injection)
    
    // Stage B (Weights)
    output logic [ADDR_WIDTH-1:0] ctrl_rd_addr_b,
    output logic                  ctrl_rd_en_b,
    output logic                  ctrl_b_accept_w, 
    output logic [$clog2(SYSTOLIC_ARRAY_WIDTH)-1:0] ctrl_b_weight_index, 

    // Stage C (Bias)
    output logic [ADDR_WIDTH-1:0] ctrl_rd_addr_c,
    output logic                  ctrl_rd_en_c,
    output logic                  ctrl_c_valid,    
    output logic [2:0]            ctrl_vpu_mode,   

    // Stage D (Writeback)
    input logic                   core_writeback_valid,
    output logic [ADDR_WIDTH-1:0] ctrl_wr_addr_d,

    // Masks
    output logic [SYSTOLIC_ARRAY_WIDTH-1:0] ctrl_row_mask,
    output logic [SYSTOLIC_ARRAY_WIDTH-1:0] ctrl_col_mask
);

    localparam W = SYSTOLIC_ARRAY_WIDTH; 
    // 计数器位宽：需要计数到 W (例如 16)，所以需要 log2(16+1) = 5 bits
    localparam CNT_WIDTH = $clog2(W + 1);
    // 长度参数位宽：同上
    localparam LEN_WIDTH = $clog2(W + 1);

    // [新增] D 阶段提前触发偏移量
    // 5 = 3 (D阶段握手延迟) + 2 (安全余量/对齐调整)
    // 这是一个固定开销，通常不随 W 变化
    localparam int D_PRE_TRIGGER_OFFSET = 5;


    // ========================================================================
    // 结构定义
    // ========================================================================
    typedef struct packed {
        logic [ADDR_WIDTH-1:0] addr_d;
        logic [ADDR_WIDTH-1:0] addr_c;
        logic [ADDR_WIDTH-1:0] addr_b;
        logic [ADDR_WIDTH-1:0] addr_a;
        logic [7:0]            len_n; // Host指令格式固定为8位
        logic [7:0]            len_k;
        logic [7:0]            len_m;
    } command_t;

    // ========================================================================
    // FIFO 逻辑
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
    // 级联触发信号与状态定义
    // ========================================================================
    logic       trigger_a_start;
    command_t   cmd_info_for_a; 
    
    logic       trigger_c_start;
    command_t   cmd_info_for_c;
    
    logic       trigger_d_queue; 
    command_t   cmd_info_for_d;

    // 状态机计数器 (使用参数化位宽)
    logic [CNT_WIDTH-1:0] cnt_b = 0;
    logic                 b_active = 0;
    
    logic [CNT_WIDTH-1:0] cnt_a = 0;
    logic                 a_active = 0;
    
    logic [CNT_WIDTH-1:0] cnt_c = 0;
    logic                 c_active = 0;
    
    // D Stage 信号
    logic [1:0] dq_wr = 0, dq_rd = 0;
    logic [2:0] dq_cnt = 0;
    logic       d_task_active = 0;
    
    // [新增] 在途任务计数器
    logic [3:0] tasks_in_flight = 0;

    assign busy = !fifo_empty || b_active || a_active || c_active || d_task_active || (dq_cnt != 0);

    // ========================================================================
    // 批次参数锁存 (Batch Configuration)
    // ========================================================================
    logic [LEN_WIDTH-1:0] active_len_k; // 控制行掩码
    logic [LEN_WIDTH-1:0] active_len_n; // 控制列掩码

    // ========================================================================
    // 在途任务计数逻辑 (解决 Gap 期间 Mask 丢失问题)
    // ========================================================================
    logic d_task_done; // 声明在前面使用

    // [修正] 将中间信号移到 always 块外部，使用 assign 进行连续赋值
    logic task_started;
    logic task_finished;

    // 定义触发条件 (组合逻辑)
    assign task_started  = b_active && (cnt_b == 0); // Stage B 刚启动任务
    assign task_finished = d_task_done;              // Stage D 完成任务

    always_ff @(posedge clk) begin
        if (rst) begin
            tasks_in_flight <= 0;
        end else begin
            // 在时序逻辑中直接使用外部定义的信号
            case ({task_started, task_finished})
                2'b10: tasks_in_flight <= tasks_in_flight + 1'b1; // 只有开始
                2'b01: tasks_in_flight <= tasks_in_flight - 1'b1; // 只有结束
                // 2'b11: 同时开始和结束，计数器不变 (含在 default 中)
                default: tasks_in_flight <= tasks_in_flight;
            endcase
        end
    end

    // ========================================================================
    // Stage B (Master) - 权重加载
    // ========================================================================
    command_t   curr_cmd_b;

    always_ff @(posedge clk) begin
        if (rst) begin
            cnt_b <= 0;
            b_active <= 0; fifo_rd_en <= 0;
            ctrl_rd_en_b <= 0; ctrl_rd_addr_b <= 0;
            trigger_a_start <= 0;
            active_len_k <= 0;
            active_len_n <= 0;
        end else begin
            fifo_rd_en <= 0;
            trigger_a_start <= 0;

            if (!b_active) begin
                // --- IDLE 状态 ---
                if (!fifo_empty) begin
                    fifo_rd_en <= 1; // Pop FIFO
                    b_active   <= 1;
                    cnt_b      <= 0; 
                    
                    // [修正] 立即锁存参数，确保 Cycle 0 的 Mask 正确
                    active_len_k <= fifo_dout.len_k[LEN_WIDTH-1:0];
                    active_len_n <= fifo_dout.len_n[LEN_WIDTH-1:0];
                end else begin
                    ctrl_rd_en_b <= 0;
                end
            end else begin
                // --- ACTIVE 状态 ---
                
                // 1. 读使能逻辑
                if (cnt_b == 0) begin
                    curr_cmd_b <= fifo_dout; 
                    ctrl_rd_en_b   <= 1'b1;
                    ctrl_rd_addr_b <= fifo_dout.addr_b; 
                end 
                else if (cnt_b < W) begin 
                    ctrl_rd_en_b   <= 1'b1;
                    ctrl_rd_addr_b <= curr_cmd_b.addr_b + ADDR_WIDTH'(cnt_b);
                end 
                else begin 
                    ctrl_rd_en_b <= 1'b0;
                end

                // 2. 计数器流转
                if (cnt_b < W) begin
                    cnt_b <= cnt_b + 1'b1;
                end 
                else begin 
                    // cnt_b == W (Gap 周期)
                    trigger_a_start <= 1'b1;
                    cmd_info_for_a  <= curr_cmd_b;
                    
                    if (!fifo_empty) begin
                        // Loop
                        fifo_rd_en <= 1;
                        cnt_b      <= 0; 
                        
                        // [修正] 连发模式下也要立即更新参数
                        active_len_k <= fifo_dout.len_k[LEN_WIDTH-1:0];
                        active_len_n <= fifo_dout.len_n[LEN_WIDTH-1:0];
                    end else begin
                        // IDLE
                        b_active <= 0;
                        cnt_b    <= 0; 
                    end
                end
            end
        end
    end

    // B-Core 控制信号
    always_ff @(posedge clk) begin
        if (rst) begin
            ctrl_b_accept_w <= 0;
            ctrl_b_weight_index <= 0;
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
    // Stage A (Input) - Follower 1 (修正时序: 0~W-1 读, 0 周期 Switch)
    // ========================================================================
    command_t   curr_cmd_a;

    always_ff @(posedge clk) begin
        if (rst) begin
            cnt_a <= 0;
            a_active <= 0; 
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
                    
                    // Cycle 0: 读 + Switch
                    ctrl_a_switch  <= 1'b1;
                    ctrl_rd_en_a   <= 1'b1;
                    ctrl_rd_addr_a <= cmd_info_for_a.addr_a;
                end else begin
                    ctrl_rd_en_a <= 0;
                end
            end else begin
                // 1. 读使能逻辑
                // Cycle 0..(W-2) -> RdEn=1; Cycle (W-1) -> RdEn=0 (为Gap做准备)
                if (cnt_a < (W - 1)) begin 
                    ctrl_rd_en_a   <= 1'b1;
                    ctrl_rd_addr_a <= ctrl_rd_addr_a + 1'b1;
                end else if (cnt_a == (W - 1)) begin
                    ctrl_rd_en_a <= 1'b0;
                end

                // 2. 计数器与触发
                if (cnt_a < W) begin
                    cnt_a <= cnt_a + 1'b1;
                    // 在 W-2 周期触发 C (C将在下一拍看到触发，再下一拍启动)
                    if (cnt_a == (W - 2)) begin
                        trigger_c_start <= 1'b1;
                        cmd_info_for_c  <= curr_cmd_a;
                    end
                end else begin
                    // cnt_a == W (Gap)
                    if (trigger_a_start) begin
                        cnt_a <= 0;
                        curr_cmd_a <= cmd_info_for_a;
                        ctrl_a_switch  <= 1'b1;
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

    // A Valid 生成
    always_ff @(posedge clk) begin
        if (rst) begin
            ctrl_a_valid <= 0;
            ctrl_psum_valid <= 0;
        end else begin
            ctrl_a_valid <= ctrl_rd_en_a;
            ctrl_psum_valid <= ctrl_rd_en_a;
        end
    end

    // ========================================================================
    // Stage C (Bias) - Follower 2 (修正时序: 同 A)
    // ========================================================================
    command_t   curr_cmd_c;

    always_ff @(posedge clk) begin
        if (rst) begin
            cnt_c <= 0;
            c_active <= 0;
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
                // 1. 读使能逻辑 (同 A, 提前一拍拉低)
                if (cnt_c < (W - 1)) begin
                    ctrl_rd_en_c   <= 1'b1;
                    ctrl_rd_addr_c <= ctrl_rd_addr_c + 1'b1;
                end else if (cnt_c == (W - 1)) begin
                    ctrl_rd_en_c <= 1'b0;
                end

                // 2. 计数器
                if (cnt_c < W) begin
                    cnt_c <= cnt_c + 1'b1;

                    // [FIX] 提前触发 D 阶段！
                    // 原来是在 else (Gap) 里触发，太晚了
                    if (cnt_c == (W - D_PRE_TRIGGER_OFFSET)) begin 
                        trigger_d_queue <= 1'b1;
                        cmd_info_for_d  <= curr_cmd_c;
                    end

                end else begin
                    // cnt_c == W (Gap)
                    // [删除] 这里的触发逻辑移到上面去了
                    // trigger_d_queue <= 1'b1;
                    // cmd_info_for_d  <= curr_cmd_c;

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

    // C Valid 生成
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
    d_info_t curr_d_info;
    logic [CNT_WIDTH-1:0] wb_row_cnt = 0; // 参数化计数器位宽

    assign done_irq = d_task_done;

    // 队列管理
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

    // 写回逻辑
    always_ff @(posedge clk) begin
        if (rst) begin
            dq_rd <= 0;
            d_task_active <= 0; wb_row_cnt <= 0; d_task_done <= 0;
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
                    
                    if (wb_row_cnt == (W - 1)) begin
                        d_task_done <= 1;
                        d_task_active <= 0; 
                    end
                end
            end
        end
    end

    // ========================================================================
    // Mask 生成逻辑 (修正版: 使用 tasks_in_flight 覆盖 Gap)
    // ========================================================================
    always_comb begin
        ctrl_row_mask = '0;
        ctrl_col_mask = '0;
        
        // 双重条件:
        // 1. busy: 覆盖 IDLE->Start 的瞬间
        // 2. tasks_in_flight: 覆盖 Stage 切换间的 Gap
        if (busy || (tasks_in_flight > 0)) begin
            
            // 行掩码
            for (int i = 0; i < W; i++) begin
                if (i < active_len_k) ctrl_row_mask[i] = 1'b1;
            end

            // 列掩码
            for (int i = 0; i < W; i++) begin
                if (i < active_len_n) ctrl_col_mask[i] = 1'b1;
            end
        end
    end

endmodule
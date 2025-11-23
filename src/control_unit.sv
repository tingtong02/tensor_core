`timescale 1ns/1ps
`default_nettype none

module control_unit #(
    parameter int ADDR_WIDTH           = 10,
    parameter int SYSTOLIC_ARRAY_WIDTH = 16
)(
    input logic clk,
    input logic rst,

    // --- 1. 主机命令接口 (Host Command Interface) ---
    input logic        cmd_valid,
    input logic [63:0] cmd_data,
    output logic       cmd_ready, 
    
    output logic       busy,      
    output logic       done_irq,  

    // --- 2. TPU 核心控制接口 (TPU Core Control Interfaces) ---
    
    // Stage A (Input Activations)
    output logic [ADDR_WIDTH-1:0] ctrl_rd_addr_a,
    output logic                  ctrl_rd_en_a,
    output logic                  ctrl_a_valid,  
    output logic                  ctrl_a_switch,
    output logic                  ctrl_psum_valid, // [NEW] 新增 Psum Valid 信号
    
    // Stage B (Weights)
    output logic [ADDR_WIDTH-1:0] ctrl_rd_addr_b,
    output logic                  ctrl_rd_en_b,
    output logic                  ctrl_b_accept_w, 
    output logic [$clog2(SYSTOLIC_ARRAY_WIDTH)-1:0] ctrl_b_weight_index, 

    // Stage C (Bias / Accumulators)
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
            wr_ptr <= 0;
            rd_ptr <= 0; 
            fifo_count <= 0;
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

    // 给状态机变量赋初始值 = 0，防止仿真初期出现不定态 (X)
    logic [4:0] cnt_b = 0;
    logic       b_active = 0;
    
    logic [4:0] cnt_a = 0;
    logic       a_active = 0;
    
    logic [4:0] cnt_c = 0;
    logic       c_active = 0;
    
    // D Stage 信号
    logic [1:0] dq_wr = 0, dq_rd = 0;
    logic [2:0] dq_cnt = 0;
    logic       d_task_active = 0;

    // Busy: 只要有任何子模块在忙，或者任务队列里有东西，模块就忙
    assign busy = !fifo_empty || b_active || a_active || c_active || d_task_active || (dq_cnt != 0);

    // ========================================================================
    // [新增] 批次参数锁存逻辑 (Batch Configuration)
    // ========================================================================
    logic [7:0] active_len_k; // 用于控制行掩码 (Rows)
    logic [7:0] active_len_n; // 用于控制列掩码 (Cols)

    // 只要 Stage B 读入新指令，就更新当前批次的尺寸配置
    // 由于你的假设：同一批次内 K/N 是不变的，所以重复赋值没有问题。
    // 当新的一批任务进入时，这里会自动更新为新的 K/N。
    always_ff @(posedge clk) begin
        if (rst) begin
            active_len_k <= 0;
            active_len_n <= 0;
        end else begin
            // 当 Stage B 处于 Active 且计数器为 0 时，说明正在读取新指令
            // 此时锁存该指令的维度信息
            if (b_active && (cnt_b == 0)) begin
                active_len_k <= curr_cmd_b.len_k;
                active_len_n <= curr_cmd_b.len_n;
            end
        end
    end

    // ========================================================================
    // Stage B (Master) - 权重加载
    // ========================================================================
    // 时序目标: t=0..15 读, t=16 Gap, t=17 Stage A 启动
    command_t   curr_cmd_b;

    always_ff @(posedge clk) begin
        if (rst) begin
            cnt_b <= 0;
            b_active <= 0; fifo_rd_en <= 0;
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
                
                // 1. 读使能逻辑 (0..15)
                if (cnt_b == 0) begin
                    // 刚开始或 Loop 回来
                    curr_cmd_b <= fifo_dout; 
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

                // 2. 计数器流转与触发逻辑
                if (cnt_b < W) begin
                    cnt_b <= cnt_b + 1'b1;
                end 
                else begin 
                    // cnt_b == 16 (Gap 周期)
                    // [修正点] 在这里触发 A。
                    // B(t=16) 触发 -> A(t=17) 启动。间隔 17 周期。
                    trigger_a_start <= 1'b1;
                    cmd_info_for_a  <= curr_cmd_b;
                    
                    if (!fifo_empty) begin
                        // 有新指令 -> Loop，无缝开始下一个任务
                        fifo_rd_en <= 1;
                        cnt_b      <= 0; 
                    end else begin
                        // 无指令 -> 回 IDLE
                        b_active <= 0;
                        cnt_b    <= 0; 
                    end
                end
            end
        end
    end

    // B-Core 控制信号生成
    always_ff @(posedge clk) begin
        if (rst) begin
            ctrl_b_accept_w <= 0;
            ctrl_b_weight_index <= 0;
        end else begin
            ctrl_b_accept_w <= ctrl_rd_en_b;
            // 仅在读使能有效时更新 Index，防止 X 态
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
    // 时序目标: 收到 Trigger 后启动，运行 16 周期
    // 并在倒数第二拍触发 Stage C (无缝衔接)
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
                    
                    ctrl_a_switch  <= 1'b1; // Start Pulse
                    ctrl_rd_en_a   <= 1'b1;
                    ctrl_rd_addr_a <= cmd_info_for_a.addr_a;
                end else begin
                    ctrl_rd_en_a <= 0;
                end
            end else begin
                // 读逻辑
                if (cnt_a < W) begin 
                    ctrl_rd_en_a   <= 1'b1;
                    ctrl_rd_addr_a <= ctrl_rd_addr_a + 1'b1; // 基于上一拍地址自增
                end else begin 
                    ctrl_rd_en_a <= 1'b0;
                end

                // 计数与触发逻辑
                if (cnt_a < W) begin
                    cnt_a <= cnt_a + 1'b1;

                    // 当 cnt_a == 15 (W-1) 时触发，C 将在 A 结束读后的下一拍立即启动
                    if (cnt_a == (W - 1)) begin
                        trigger_c_start <= 1'b1;
                        cmd_info_for_c  <= curr_cmd_a;
                    end
                end else begin
                    // cnt_a == 16 (Gap Done)
                    if (trigger_a_start) begin
                        // 流水线重叠: 收到上级的新触发，直接重置
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
        ctrl_psum_valid <= 0; // [NEW]
        end else begin
        ctrl_a_valid <= ctrl_rd_en_a;
        ctrl_psum_valid <= ctrl_rd_en_a; // [NEW] 逻辑与 A Valid 完全同步
        end
    end

    // ========================================================================
    // Stage C (Bias) - Follower 2
    // ========================================================================
    // 时序目标: 紧跟 A 之后运行
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
                // 读逻辑
                if (cnt_c < W) begin
                    ctrl_rd_en_c   <= 1'b1;
                    ctrl_rd_addr_c <= ctrl_rd_addr_c + 1'b1;
                end else begin
                    ctrl_rd_en_c <= 1'b0;
                end

                // 计数逻辑
                if (cnt_c < W) begin
                    cnt_c <= cnt_c + 1'b1;
                end else begin
                    // 完成一次 Bias 加载，将任务推入写回队列 D
                    trigger_d_queue <= 1'b1;
                    cmd_info_for_d  <= curr_cmd_c;

                    if (trigger_c_start) begin
                        // Pipeline Overlap
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
    logic       d_task_done = 0;
    d_info_t    curr_d_info;
    logic [7:0] wb_row_cnt = 0;

    assign done_irq = d_task_done;

    // 队列管理
    always_ff @(posedge clk) begin
        if (rst) begin
            dq_wr <= 0;
            dq_cnt <= 0;
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
                // 等待计算核心发出 Writeback Valid 信号
                if (core_writeback_valid) begin
                    wb_row_cnt <= wb_row_cnt + 1'b1;
                    ctrl_wr_addr_d <= ctrl_wr_addr_d + 1'b1; 
                    
                    // 始终接收 W (16) 行数据
                    if (wb_row_cnt == (W - 1)) begin
                        d_task_done <= 1;
                        d_task_active <= 0; 
                    end
                end
            end
        end
    end

    // ========================================================================
    // [修改] Mask 生成逻辑
    // ========================================================================
    always_comb begin
        ctrl_row_mask = '0;
        ctrl_col_mask = '0;
        
        // 只要系统处于忙碌状态 (Busy)，就根据当前锁存的批次参数打开 PE 阵列
        // 这保证了:
        // 1. Stage B (权重加载) 期间，Mask 为 1 -> PE Enable -> 权重正确锁存
        // 2. Stage A (计算) 期间，Mask 为 1 -> PE Enable -> 计算进行
        // 3. Stage D (写回) 期间，Mask 为 1 -> 输出有效
        if (busy) begin
            // 行掩码 (由 K 决定)
            for (int i = 0; i < W; i++) begin
                if (i < active_len_k) ctrl_row_mask[i] = 1'b1;
            end

            // 列掩码 (由 N 决定)
            for (int i = 0; i < W; i++) begin
                if (i < active_len_n) ctrl_col_mask[i] = 1'b1;
            end
        end
    end

endmodule
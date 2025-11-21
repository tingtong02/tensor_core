`timescale 1ns/1ps
`default_nettype none

/**
 * 模块名: control_unit
 * 功能: TPU 核心控制器 (支持指令队列与级联流水线)
 * * 接口规范:
 * 1. Host Interface: 64-bit Command FIFO Write Port
 * - cmd_payload format:
 * [63:54] Addr D (10b)
 * [53:44] Addr C (10b)
 * [43:34] Addr B (10b)
 * [33:24] Addr A (10b)
 * [23:16] N (8b)
 * [15:8]  K (8b)
 * [7:0]   M (8b)
 * * 2. Timing Logic (User Spec):
 * - Input Buffer Read: Cycles 0~15 (Duration 16)
 * - TPU Core Control : Cycles 1~16 (Aligned with Data)
 * - Cycle 17         : Gap / Switch / Next Task Trigger
 */
module control_unit #(
    parameter int ADDR_WIDTH           = 10,
    parameter int SYSTOLIC_ARRAY_WIDTH = 16
)(
    input logic clk,
    input logic rst,

    // ========================================================================
    // 1. Host Command Interface (FIFO Write Side)
    // ========================================================================
    input logic        cmd_valid,
    input logic [63:0] cmd_data,
    output logic       cmd_ready, // 1 = FIFO Not Full, can accept command
    
    // Status
    output logic       busy,      // 1 = Processing tasks
    output logic       done_irq,  // Pulse when a task completes writeback

    // ========================================================================
    // 2. TPU Core Control Interfaces
    // ========================================================================
    
    // --- A-Flow (Input) ---
    output logic [ADDR_WIDTH-1:0] ctrl_rd_addr_a,
    output logic                  ctrl_rd_en_a,
    output logic                  ctrl_a_valid,  // Delayed by 1 cycle
    output logic                  ctrl_a_switch, // Pulse at Start of A-Flow
    
    // --- B-Flow (Weight) ---
    output logic [ADDR_WIDTH-1:0] ctrl_rd_addr_b,
    output logic                  ctrl_rd_en_b,
    output logic                  ctrl_b_accept_w, // Delayed by 1 cycle
    output logic [$clog2(SYSTOLIC_ARRAY_WIDTH)-1:0] ctrl_b_weight_index, // Delayed

    // --- C-Flow (Bias) ---
    output logic [ADDR_WIDTH-1:0] ctrl_rd_addr_c,
    output logic                  ctrl_rd_en_c,
    output logic                  ctrl_c_valid,    // Delayed by 1 cycle
    output logic [2:0]            ctrl_vpu_mode,   // Fixed to 001 (Add)

    // --- D-Flow (Writeback) ---
    input logic                   core_writeback_valid,
    output logic [ADDR_WIDTH-1:0] ctrl_wr_addr_d,

    // --- Masks ---
    output logic [SYSTOLIC_ARRAY_WIDTH-1:0] ctrl_row_mask,
    output logic [SYSTOLIC_ARRAY_WIDTH-1:0] ctrl_col_mask
);

    localparam W = SYSTOLIC_ARRAY_WIDTH; // 16

    // ========================================================================
    // 内部结构定义: 指令解包
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
    // 模块 1: Host Command FIFO (Depth 4)
    // ========================================================================
    logic       fifo_empty;
    logic       fifo_rd_en;
    command_t   fifo_dout;
    logic       fifo_full;

    // 简单的同步 FIFO 实现
    logic [63:0] mem_fifo [4];
    logic [1:0]  wr_ptr, rd_ptr;
    logic [2:0]  fifo_count;

    assign cmd_ready = !fifo_full;
    assign fifo_full = (fifo_count == 3'd4);
    assign fifo_empty = (fifo_count == 3'd0);
    assign fifo_dout  = command_t'(mem_fifo[rd_ptr]); // Cast 64-bit to struct

    always_ff @(posedge clk) begin
        if (rst) begin
            wr_ptr <= 0; rd_ptr <= 0; fifo_count <= 0;
        end else begin
            // Push
            if (cmd_valid && !fifo_full) begin
                mem_fifo[wr_ptr] <= cmd_data;
                wr_ptr <= wr_ptr + 1'b1;
            end
            // Pop
            if (fifo_rd_en && !fifo_empty) begin
                rd_ptr <= rd_ptr + 1'b1;
            end
            // Count Update
            case ({cmd_valid && !fifo_full, fifo_rd_en && !fifo_empty})
                2'b10: fifo_count <= fifo_count + 1'b1;
                2'b01: fifo_count <= fifo_count - 1'b1;
                default: fifo_count <= fifo_count;
            endcase
        end
    end

    // ========================================================================
    // 模块 2: 全局级联触发信号 (Handshake between Stages)
    // ========================================================================
    // Stage B (Master) -> triggers -> Stage A -> triggers -> Stage C
    // 还需要将 Command 信息沿流水线传递
    
    // B -> A 的传递信息
    logic       trigger_a_start;
    command_t   cmd_info_for_a; 
    
    // A -> C 的传递信息
    logic       trigger_c_start;
    command_t   cmd_info_for_c;

    // C -> D (Writeback) 的传递信息
    logic       trigger_d_queue; // C 完成后，将 D 信息推入写回队列
    command_t   cmd_info_for_d;

    assign busy = !fifo_empty; // 简化状态指示，只要有指令就Busy

    // ========================================================================
    // 模块 3: Stage B (权重加载) - 主节奏发生器
    // ========================================================================
    // 负责从 FIFO 取指令，执行 B 加载，完成后触发 A
    
    logic [4:0] cnt_b; // 0 to 17
    logic       b_active;
    command_t   curr_cmd_b;

    always_ff @(posedge clk) begin
        if (rst) begin
            cnt_b <= 0; b_active <= 0; fifo_rd_en <= 0;
            ctrl_rd_en_b <= 0; ctrl_rd_addr_b <= 0;
            trigger_a_start <= 0;
        end else begin
            // 默认信号
            fifo_rd_en <= 0;
            trigger_a_start <= 0;

            if (!b_active) begin
                // IDLE: Check FIFO
                if (!fifo_empty) begin
                    fifo_rd_en <= 1; // Pop command
                    b_active   <= 1;
                    cnt_b      <= 0;
                    // 注意：FIFO数据在下一拍才有效，所以这里不能直接锁存 fifo_dout
                    // 我们需要在下一拍锁存
                end
            end else begin
                // ACTIVE
                
                // 周期 0: 锁存指令 (因为上一拍发出了 Pop)
                if (cnt_b == 0) begin
                    curr_cmd_b <= fifo_dout;
                    // 发出第一个读请求
                    ctrl_rd_en_b   <= 1'b1;
                    ctrl_rd_addr_b <= fifo_dout.addr_b; // Addr + 0
                end 
                // 周期 1~15: 继续读请求
                else if (cnt_b < W) begin // 1 to 15
                    ctrl_rd_en_b   <= 1'b1;
                    ctrl_rd_addr_b <= curr_cmd_b.addr_b + ADDR_WIDTH'(cnt_b);
                end 
                // 周期 16: 停止读，间隙 (Gap)，触发下一级
                else if (cnt_b == W) begin
                    ctrl_rd_en_b <= 1'b0;
                    // 传递指令信息给 A 阶段
                    cmd_info_for_a <= curr_cmd_b;
                    trigger_a_start <= 1'b1; 
                end
                // 周期 17: 检查是否循环
                else begin // cnt_b == 17
                    // 检查 FIFO 是否有新指令，实现无缝背靠背 (Back-to-Back)
                    if (!fifo_empty) begin
                        fifo_rd_en <= 1; // Pop next
                        cnt_b <= 0;      // 重置计数器，立即开始
                        // b_active 保持 1
                    end else begin
                        b_active <= 0;   // 回到 IDLE
                    end
                end

                // 计数器自增 (除非被重置)
                if (cnt_b <= W) cnt_b <= cnt_b + 1'b1;
            end
        end
    end

    // --- 生成 B 的延迟控制信号 (给 TPU Core) ---
    // 核心逻辑: 所有的 Core Control 信号都是 rd_en 的 1 周期延迟
    always_ff @(posedge clk) begin
        if (rst) begin
            ctrl_b_accept_w <= 0; ctrl_b_weight_index <= 0;
        end else begin
            // Valid 跟随 rd_en
            ctrl_b_accept_w <= ctrl_rd_en_b;
            
            // Index 生成: 倒序 (W-1 down to 0)
            // 当 cnt_b=0 时发出读 req，cnt_b=1 时数据到，此时 Index 应为 15
            if (ctrl_rd_en_b) begin
                // 利用当前的 cnt_b 计算。注意 cnt_b 在这里已经是下一拍的值了
                // 比如 cnt_b 从 0 变 1，此时 rd_en=1。
                // 我们希望 index 对应的是 rd_addr 的偏移。
                // rd_addr = base + (cnt_b - 1 if we consider logic delay)
                // 简化：直接用寄存器做减法
                // 目标: 第一拍(数据有效时) Index=15, 最后一拍 Index=0
                if (cnt_b == 0) 
                    ctrl_b_weight_index <= ($clog2(W))'(W - 1); // init
                else 
                    ctrl_b_weight_index <= ctrl_b_weight_index - 1'b1;
            end
        end
    end

    // ========================================================================
    // 模块 4: Stage A (输入流 & Switch) - 跟随者 1
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
            // Pulse reset
            ctrl_a_switch <= 0;
            trigger_c_start <= 0;

            if (!a_active) begin
                if (trigger_a_start) begin
                    a_active <= 1;
                    cnt_a <= 0;
                    curr_cmd_a <= cmd_info_for_a; // 锁存传递来的指令
                    
                    // [关键]: Switch 信号在 T=W (也就是 A 开始的那一瞬间) 发出
                    ctrl_a_switch <= 1'b1; 
                    
                    // 发出第一个读请求
                    ctrl_rd_en_a   <= 1'b1;
                    ctrl_rd_addr_a <= cmd_info_for_a.addr_a; // Base + 0
                end
            end else begin
                // 周期 1~15
                if (cnt_a < W-1) begin // cnt_a is 0..14 here (executing for next cycle 1..15)
                    ctrl_rd_en_a   <= 1'b1;
                    ctrl_rd_addr_a <= ctrl_rd_addr_a + 1'b1;
                end
                // 周期 16: Gap
                else if (cnt_a == W-1) begin
                     ctrl_rd_en_a <= 1'b0;
                end
                // 周期 17: Done
                else if (cnt_a == W) begin
                    // 触发下一级
                    cmd_info_for_c <= curr_cmd_a;
                    trigger_c_start <= 1'b1;
                    
                    // 检查是否有新的触发 (Pipelining)
                    if (trigger_a_start) begin
                        cnt_a <= 0;
                        curr_cmd_a <= cmd_info_for_a;
                        ctrl_a_switch <= 1'b1;
                        ctrl_rd_en_a   <= 1'b1;
                        ctrl_rd_addr_a <= cmd_info_for_a.addr_a;
                    end else begin
                        a_active <= 0;
                    end
                end
                
                if (cnt_a <= W) cnt_a <= cnt_a + 1'b1;
            end
        end
    end

    // A Valid 延迟生成
    always_ff @(posedge clk) begin
        if (rst) ctrl_a_valid <= 0;
        else ctrl_a_valid <= ctrl_rd_en_a;
    end

    // ========================================================================
    // 模块 5: Stage C (Bias 流) - 跟随者 2
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
                    
                    // 启动读
                    ctrl_rd_en_c   <= 1'b1;
                    ctrl_rd_addr_c <= cmd_info_for_c.addr_c;
                end
            end else begin
                // 0..15
                if (cnt_c < W-1) begin
                    ctrl_rd_en_c   <= 1'b1;
                    ctrl_rd_addr_c <= ctrl_rd_addr_c + 1'b1;
                end
                // 16: Gap
                else if (cnt_c == W-1) begin
                    ctrl_rd_en_c <= 1'b0;
                end
                // 17: Done
                else if (cnt_c == W) begin
                    // Bias 阶段完成，意味着所有的配置信息已经流过阵列
                    // 将 D 的信息推入写回队列
                    cmd_info_for_d <= curr_cmd_c;
                    trigger_d_queue <= 1'b1;

                    if (trigger_c_start) begin
                        cnt_c <= 0;
                        curr_cmd_c <= cmd_info_for_c;
                        ctrl_rd_en_c   <= 1'b1;
                        ctrl_rd_addr_c <= cmd_info_for_c.addr_c;
                    end else begin
                        c_active <= 0;
                    end
                end
                
                if (cnt_c <= W) cnt_c <= cnt_c + 1'b1;
            end
        end
    end

    // C Valid 延迟生成
    always_ff @(posedge clk) begin
        if (rst) ctrl_c_valid <= 0;
        else ctrl_c_valid <= ctrl_rd_en_c;
    end
    
    assign ctrl_vpu_mode = 3'b001; // Always Add

    // ========================================================================
    // 模块 6: Stage D (写回队列与逻辑)
    // ========================================================================
    // 我们需要一个队列来存储 "等待写回的任务信息"
    // 因为 Pipeline 很长，可能同时有多个任务在排队写回
    
    typedef struct packed {
        logic [ADDR_WIDTH-1:0] addr_d;
        logic [7:0]            len_m;
        logic [7:0]            len_n;
        logic [7:0]            len_k;
    } d_info_t;

    d_info_t d_queue [4];
    logic [1:0] dq_wr, dq_rd;
    logic [2:0] dq_cnt;
    
    // Queue Push Logic (From Stage C)
    always_ff @(posedge clk) begin
        if (rst) begin
            dq_wr <= 0; dq_cnt <= 0;
        end else begin
            // Push
            if (trigger_d_queue) begin
                d_queue[dq_wr].addr_d <= cmd_info_for_d.addr_d;
                d_queue[dq_wr].len_m  <= cmd_info_for_d.len_m;
                d_queue[dq_wr].len_n  <= cmd_info_for_d.len_n;
                d_queue[dq_wr].len_k  <= cmd_info_for_d.len_k;
                dq_wr <= dq_wr + 1'b1;
                dq_cnt <= dq_cnt + 1'b1; // Assume not full for simplicity
            end 
            // Pop (See below)
            else if (d_task_done) begin
                dq_cnt <= dq_cnt - 1'b1;
            end
        end
    end

    // Writeback Logic
    logic [7:0] wb_row_cnt;
    logic       d_task_active;
    logic       d_task_done;
    d_info_t    curr_d_info;

    assign done_irq = d_task_done;

    always_ff @(posedge clk) begin
        if (rst) begin
            dq_rd <= 0; d_task_active <= 0; wb_row_cnt <= 0; d_task_done <= 0;
            ctrl_wr_addr_d <= 0;
        end else begin
            d_task_done <= 0;

            if (!d_task_active) begin
                // 如果队列有任务，开始监控写回
                if (dq_cnt > 0) begin
                    curr_d_info <= d_queue[dq_rd];
                    dq_rd <= dq_rd + 1'b1;
                    d_task_active <= 1;
                    wb_row_cnt <= 0;
                    ctrl_wr_addr_d <= d_queue[dq_rd].addr_d; // Load Base
                end
            end else begin
                // 动态生成 Masks (根据当前任务的 N 和 K)
                // 注意: 这里其实应该一直驱动 Mask，但为了简化，我们假设
                // 任务切换间隙的 Mask 抖动不影响 (因为 Valid=0)
                
                if (core_writeback_valid) begin
                    // 收到一行有效数据
                    wb_row_cnt <= wb_row_cnt + 1'b1;
                    ctrl_wr_addr_d <= ctrl_wr_addr_d + 1'b1; // Auto inc

                    // 检查是否完成了所有行 (M)
                    // 如果 M < 16，mask 会处理多余的行，
                    // 但 core_writeback_valid 依然会产生 16 次 (基于 core 逻辑)
                    // 或者我们需要在 core 里做计数？
                    // 根据 tpu_core 代码，它产生 Valid 取决于 aligned_valid_pipe。
                    // 只要 Pipe 里有数据，它就会吐出来。阵列总是吐出 16 行。
                    // 所以我们需要等待 16 个 valid 信号，而不是 M 个。
                    // 只有 M 个会被有效写入 (如果 Output Buffer 有 Mask 逻辑，
                    // 但目前的 Output Buffer 是全写的，只是我们只关心前 M 行)。
                    // 实际上，tpu_core 并没有行掩码逻辑去 *阻止* writeback valid，
                    // 只是行掩码让输入为 0。
                    // 所以我们应该等待 16 个 writeback valid。
                    
                    if (wb_row_cnt == (W - 1)) begin
                        d_task_done <= 1; // 完成中断
                        d_task_active <= 0; 
                    end
                end
            end
        end
    end

    // ========================================================================
    // 模块 7: 掩码生成 (Mask Generation)
    // ========================================================================
    // Mask 应该对应当前正在计算的任务。
    // 由于流水线存在，哪个任务决定 Mask？
    // 通常是正在进行 "Input Stream" 的任务决定 Row Mask (K)，
    // 正在进行 "Writeback" 的任务决定 Col Mask (N)。
    // 为了简化，我们假设 Mask 信号在任务执行期间由 Writeback 阶段的信息驱动
    // 或者由 Stage A (K) 和 Stage D (N) 混合驱动。
    // 最稳妥的方式：Mask 信号给 tpu_core，tpu_core 内部 latch 吗？
    // tpu_core 没有 latch mask。
    // 这是一个潜在的冒险：如果 Pipeline 中有不同维度的任务，Mask 会冲突。
    // **解决方案**: 假设 Host 会保证连续提交的任务具有相同的维度，
    // 或者在维度变化时等待 Done。
    // 这里我们使用 Stage A 的 info 来驱动 Row Mask (影响输入)，
    // 使用 Stage D 的 info 来驱动 Col Mask (影响输出)。

    always_comb begin
        ctrl_row_mask = '0;
        ctrl_col_mask = '0;
        
        // K Mask (由 Stage A 控制输入)
        for (int i = 0; i < W; i++) begin
            if (i < curr_cmd_a.len_k) ctrl_row_mask[i] = 1'b1;
        end
        // 如果 Stage A 闲置，保持 0 或者维持上一个值 (这里置 0)
        if (!a_active) ctrl_row_mask = '0; // 或者全 1 也可以

        // N Mask (由 Stage D 控制输出)
        for (int i = 0; i < W; i++) begin
            if (i < curr_d_info.len_n) ctrl_col_mask[i] = 1'b1;
        end
        // 如果 Stage D 还没有 active (刚开始)，可以用 Stage C 或 FIFO 头的 N 预判
        // 为安全起见，Idle 时全屏蔽
         if (!d_task_active) ctrl_col_mask = '0;
    end

endmodule
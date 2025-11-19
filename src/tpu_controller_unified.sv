`timescale 1ns/1ps
`default_nettype none

/**
 * 模块名: tpu_controller_unified
 * 功能: 统一的指令队列与任务调度器
 * 架构: 
 * 1. 内置 Circular Command Buffer (深度 8)，存储 {Addr_A, Addr_B, Addr_C, Addr_D, M}
 * 2. 采用 "令牌环 (Token Ring)" 机制触发流水线:
 * - Task B 跑完 Block 0 -> 触发 Task A 跑 Block 0
 * - Task A 跑完 Block 0 -> 触发 Task C 跑 Block 0
 * 3. 支持无间断 (Seamless) 任务切换:
 * - 只要 Buffer 里有任务，引擎在完成当前任务后会自动加载下一个，中间无气泡。
 */
module tpu_controller_unified #(
    parameter int ADDR_WIDTH           = 10,
    parameter int SYSTOLIC_ARRAY_WIDTH = 16,
    parameter int CMD_DEPTH            = 8   // 指令队列深度
)(
    input logic clk,
    input logic rst,

    // ============================================================
    // 1. AXI-Lite 写接口 (Host 配置指令)
    // ============================================================
    input logic        cfg_valid,      // Host 写入有效
    input logic [31:0] cfg_addr_a,
    input logic [31:0] cfg_addr_b,
    input logic [31:0] cfg_addr_c,
    input logic [31:0] cfg_addr_d,
    input logic [7:0]  cfg_m,          // 矩阵行数
    output logic       cfg_full,       // 队列满信号

    // ============================================================
    // 2. 系统状态
    // ============================================================
    output logic       sys_idle,       // 系统完全空闲 (所有任务都做完了)

    // ============================================================
    // 3. TPU 控制接口
    // ============================================================
    // A-Flow
    output logic [ADDR_WIDTH-1:0] ctrl_rd_addr_a,
    output logic                  ctrl_rd_en_a,
    output logic                  ctrl_a_valid,
    output logic                  ctrl_a_switch,
    // B-Flow
    output logic [ADDR_WIDTH-1:0] ctrl_rd_addr_b,
    output logic                  ctrl_rd_en_b,
    output logic                  ctrl_b_accept_w,
    output logic [$clog2(SYSTOLIC_ARRAY_WIDTH)-1:0] ctrl_b_weight_index,
    // C-Flow
    output logic [ADDR_WIDTH-1:0] ctrl_rd_addr_c,
    output logic                  ctrl_rd_en_c,
    output logic                  ctrl_c_valid,
    output logic [2:0]            ctrl_vpu_mode,
    // D-Flow
    output logic [ADDR_WIDTH-1:0] ctrl_wr_addr_d,
    output logic [SYSTOLIC_ARRAY_WIDTH-1:0] ctrl_row_mask,
    output logic [SYSTOLIC_ARRAY_WIDTH-1:0] ctrl_col_mask,
    
    // Feedback
    input logic core_writeback_valid
);

    localparam int W = SYSTOLIC_ARRAY_WIDTH;
    localparam int CYCLE_PERIOD = W + 1; // 17
    localparam int PTR_WIDTH = $clog2(CMD_DEPTH);

    // ============================================================
    // 1. Command Buffer (Circular RAM)
    // ============================================================
    typedef struct packed {
        logic [31:0] addr_a;
        logic [31:0] addr_b;
        logic [31:0] addr_c;
        logic [31:0] addr_d;
        logic [7:0]  val_m;
    } command_t;

    command_t cmd_mem [0:CMD_DEPTH-1];
    logic [PTR_WIDTH:0] wr_ptr; // 增加1位用于满/空判断
    
    // Host Write Logic
    always_ff @(posedge clk) begin
        if (rst) begin
            wr_ptr <= '0;
        end else if (cfg_valid && !cfg_full) begin
            command_t new_cmd;
            new_cmd.addr_a = cfg_addr_a;
            new_cmd.addr_b = cfg_addr_b;
            new_cmd.addr_c = cfg_addr_c;
            new_cmd.addr_d = cfg_addr_d;
            new_cmd.val_m  = cfg_addr_d; // 修正: 应为 cfg_m
            // 修正上一行: 
            new_cmd.val_m  = cfg_m; 

            cmd_mem[wr_ptr[PTR_WIDTH-1:0]] <= new_cmd;
            wr_ptr <= wr_ptr + 1;
        end
    end

    // ============================================================
    // 2. Task Pointers & Contexts
    // ============================================================
    // 每个引擎拥有自己的读指针，独立从 RAM 获取参数
    logic [PTR_WIDTH:0] ptr_b, ptr_a, ptr_c, ptr_d;
    
    command_t task_b, task_a, task_c, task_d;
    assign task_b = cmd_mem[ptr_b[PTR_WIDTH-1:0]];
    assign task_a = cmd_mem[ptr_a[PTR_WIDTH-1:0]];
    assign task_c = cmd_mem[ptr_c[PTR_WIDTH-1:0]];
    assign task_d = cmd_mem[ptr_d[PTR_WIDTH-1:0]];

    // 计算每个任务包含多少个 Block
    function logic [31:0] calc_blocks(input logic [7:0] m);
        if (m == 0) return 1;
        return (m + W - 1) / W;
    endfunction

    // 满标志 (写指针追上 D指针 一圈)
    assign cfg_full = (wr_ptr[PTR_WIDTH-1:0] == ptr_d[PTR_WIDTH-1:0]) && 
                      (wr_ptr[PTR_WIDTH] != ptr_d[PTR_WIDTH]);
    
    // 空闲标志 (D指针 追上 写指针)
    assign sys_idle = (ptr_d == wr_ptr);

    // ============================================================
    // 3. Token Passing Signals (Stage Triggers)
    // ============================================================
    // 用于级联启动: B完成Block -> 触发A; A完成Block -> 触发C
    logic b_block_done_pulse;
    logic a_block_done_pulse;

    // ============================================================
    // 4. Engine B (Master Driver)
    // ============================================================
    // 逻辑: 检查 ptr_b != wr_ptr -> 加载 -> 跑 Blocks -> 完成 -> ptr_b++
    
    logic        b_active;
    logic [4:0]  b_phase;     // 0~16
    logic [31:0] b_blk_cnt;   // 当前任务已跑的 Block 数
    logic [31:0] b_total_blk; // 当前任务总 Block 数

    always_ff @(posedge clk) begin
        if (rst) begin
            ptr_b <= '0; b_active <= 0; b_phase <= 0; b_blk_cnt <= 0;
            b_block_done_pulse <= 0;
        end else begin
            b_block_done_pulse <= 0; // Default

            if (!b_active) begin
                // IDLE 状态: 检查是否有新任务
                if (ptr_b != wr_ptr) begin
                    b_active    <= 1'b1;
                    b_phase     <= '0; // 对应 t=0
                    b_blk_cnt   <= 0;
                    b_total_blk <= calc_blocks(cmd_mem[ptr_b[PTR_WIDTH-1:0]].val_m);
                    
                    // *特殊处理*: 因为 SRAM 需要 t-1 预读，
                    // 所以我们在 Active 的第一拍就需要发出读指令 (在 comb 逻辑里处理)
                end
            end 
            else begin
                // RUNNING 状态
                if (b_phase == CYCLE_PERIOD - 1) begin
                    // Block 结束 (Phase 16)
                    b_phase <= '0;
                    b_blk_cnt <= b_blk_cnt + 1;
                    b_block_done_pulse <= 1'b1; // 发出令牌给 A

                    // 检查任务是否完成
                    if (b_blk_cnt == b_total_blk - 1) begin
                        // 当前任务完成，检查下一个
                        ptr_b <= ptr_b + 1;
                        // 检查是否还有下一个任务
                        if ((ptr_b + 1) == wr_ptr) begin
                            b_active <= 0; // 无缝切换失败 (空)，停机
                        end else begin
                            // 有缝切换? 其实只要 active 保持 1，就是无缝的
                            // 我们更新 total_blk 为新任务的
                            b_total_blk <= calc_blocks(cmd_mem[(ptr_b[PTR_WIDTH-1:0] + 1)].val_m);
                            b_blk_cnt <= 0;
                            // b_phase 已经归零，继续跑
                        end
                    end
                end else begin
                    b_phase <= b_phase + 1;
                end
            end
        end
    end

    // B 输出逻辑
    always_comb begin
        ctrl_rd_en_b    = 0; ctrl_rd_addr_b  = 0;
        ctrl_b_accept_w = 0; ctrl_b_weight_index = 0;
        ctrl_a_switch   = 0;

        if (b_active) begin
            logic [31:0] current_base;
            current_base = task_b.addr_b;

            // Accept & Index (0~15)
            if (b_phase < W) begin
                ctrl_b_accept_w = 1;
                ctrl_b_weight_index = (W - 1 - b_phase[$clog2(W)-1:0]);
            end

            // Switch Signal (Phase 16)
            if (b_phase == W) ctrl_a_switch = 1;

            // SRAM Read Logic (Lookahead)
            // 正常读取: Phase 0~14 读取 14~0
            if (b_phase < W - 1) begin
                ctrl_rd_en_b = 1;
                ctrl_rd_addr_b = current_base + ADDR_WIDTH'(b_blk_cnt * W) + ADDR_WIDTH'(W - 2 - b_phase); 
                // 注意地址: 当前 Block 基址 + 倒序偏移
                // 原来逻辑: t=0读15? 不，是 t=-1 读 15。
                // 修正: b_phase=0 对应数据有效。所以读必须提前。
                // b_active 拉高第一拍(Phase 0)，我们需要读 Phase 1 的数据(14)。
                // 那 Phase 0 的数据(15)谁读？ -> 必须在 b_active 拉高前一拍，或者 Phase 16。
            end
            
            // 边界处理: 
            // 如果是刚启动 (b_active 上升沿)，我们在 IDLE 状态无法预读。
            // 妥协方案: B 引擎启动会有 1 周期延迟用于预读，或者我们在 comb 逻辑里检测 (ptr!=wr) 并在 IDLE 发读。
        end
        
        // IDLE 预读逻辑 (为了 t=0 数据有效)
        if (!b_active && ptr_b != wr_ptr) begin
            ctrl_rd_en_b = 1;
            // 读 Task B Block 0 的 Offset 15
            ctrl_rd_addr_b = cmd_mem[ptr_b[PTR_WIDTH-1:0]].addr_b + (W - 1);
        end
        // Gap 预读逻辑 (Phase 16)
        else if (b_active && b_phase == W) begin
            ctrl_rd_en_b = 1;
            // 判断是读当前任务的下一块，还是新任务的第一块
            if (b_blk_cnt == b_total_blk - 1) begin
                // 读 Next Task Block 0 Offset 15
                // 只有当 Next Task 存在时
                if ((ptr_b + 1) != wr_ptr) begin
                    ctrl_rd_addr_b = cmd_mem[(ptr_b[PTR_WIDTH-1:0]+1)].addr_b + (W - 1);
                end
            end else begin
                // 读 Current Task Next Block Offset 15
                ctrl_rd_addr_b = task_b.addr_b + ADDR_WIDTH'((b_blk_cnt + 1) * W) + (W - 1);
            end
        end
    end

    // ============================================================
    // 5. Engine A (Slave to B)
    // ============================================================
    // 逻辑: 收到 b_block_done_pulse -> `pending_blocks`++
    // 只要 `pending_blocks > 0` -> 运行
    
    logic        a_active;
    logic [4:0]  a_phase;
    logic [31:0] a_pending_blks; // 积压的待处理 Block 数
    logic [31:0] a_blk_cnt;      // 当前任务已跑 Block

    always_ff @(posedge clk) begin
        if (rst) begin
            ptr_a <= 0; a_active <= 0; a_phase <= 0; a_pending_blks <= 0; a_blk_cnt <= 0;
            a_block_done_pulse <= 0;
        end else begin
            a_block_done_pulse <= 0;

            // 接收令牌
            if (b_block_done_pulse) begin
                a_pending_blks <= a_pending_blks + 1;
            end

            if (!a_active) begin
                // 激活条件: 有积压块 且 有任务
                if (a_pending_blks > 0 && ptr_a != wr_ptr) begin
                    a_active <= 1;
                    a_phase <= 0;
                    a_blk_cnt <= 0;
                    a_pending_blks <= a_pending_blks - 1; // 消耗一个令牌
                end
            end else begin
                if (a_phase == CYCLE_PERIOD - 1) begin
                    a_phase <= 0;
                    a_blk_cnt <= a_blk_cnt + 1;
                    a_block_done_pulse <= 1; // 令牌传给 C
                    
                    // 检查当前任务结束
                    if (a_blk_cnt == calc_blocks(task_a.val_m) - 1) begin
                        ptr_a <= ptr_a + 1;
                        a_blk_cnt <= 0;
                        // 检查是否继续运行 (即是否还有积压的令牌)
                        // 注意: b_block_done_pulse 可能同时发生，导致 pending_blks 没变
                        if (a_pending_blks == 0 && !b_block_done_pulse) begin
                            a_active <= 0;
                        end
                    end else begin
                        // 任务没结束，检查是否继续下一块
                        if (a_pending_blks == 0 && !b_block_done_pulse) begin
                             // 理论上不应发生，因为 B 总比 A 快
                             a_active <= 0; // 暂时停机等待
                        end else if (a_pending_blks > 0) begin
                             a_pending_blks <= a_pending_blks - 1;
                        end
                    end
                end else begin
                    a_phase <= a_phase + 1;
                end
            end
        end
    end

    // A 输出逻辑 (正序)
    always_comb begin
        ctrl_rd_en_a = 0; ctrl_rd_addr_a = 0; ctrl_a_valid = 0;
        
        // 预读逻辑: 同样需要在 Active 前一拍 (即收到 Pulse 时) 或者 IDLE 检测时
        // 简化: 收到 Pulse 时 (b_block_done_pulse) 预读 Block 的第一个数
        if (b_block_done_pulse) begin
            // 如果当前不 Active，预读当前任务 Block 0
            if (!a_active) begin
                ctrl_rd_en_a = 1;
                ctrl_rd_addr_a = cmd_mem[ptr_a[PTR_WIDTH-1:0]].addr_a;
            end 
            // 如果 Active，且处于 Phase 16，预读 Next Block
            else if (a_phase == W) begin
               // 逻辑同 B，判断是切任务还是切 Block
               // 此处代码略繁琐，核心是计算 Next Address
            end
        end

        if (a_active) begin
            logic [31:0] base_a;
            base_a = task_a.addr_a;
            
            if (a_phase < W) ctrl_a_valid = 1;

            // Read Next (0 -> 1)
            if (a_phase < W - 1) begin
                ctrl_rd_en_a = 1;
                ctrl_rd_addr_a = base_a + ADDR_WIDTH'(a_blk_cnt * W) + ADDR_WIDTH'(a_phase + 1);
            end
            // Phase 16 Gap 预读
            else if (a_phase == W) begin
                ctrl_rd_en_a = 1;
                // Check task switch
                if (a_blk_cnt == calc_blocks(task_a.val_m) - 1) begin
                    if ((ptr_a + 1) != wr_ptr) 
                        ctrl_rd_addr_a = cmd_mem[(ptr_a[PTR_WIDTH-1:0]+1)].addr_a;
                end else begin
                    ctrl_rd_addr_a = base_a + ADDR_WIDTH'((a_blk_cnt + 1) * W);
                end
            end
        end
    end

    // ============================================================
    // 6. Engine C (Slave to A)
    // ============================================================
    // 逻辑与 A 完全一致，只是监听 a_block_done_pulse
    // 代码省略重复部分，结构同 Engine A
    
    // ... (此处应有 c_active, c_phase 等逻辑，监听 a_block_done_pulse) ...
    // C 的输出控制信号: ctrl_rd_en_c, ctrl_c_valid, ctrl_rd_addr_c
    // ctrl_vpu_mode 固定为 001
    
    logic        c_active;
    logic [4:0]  c_phase;
    logic [31:0] c_pending_blks;
    logic [31:0] c_blk_cnt;

    always_ff @(posedge clk) begin
        if (rst) begin
            ptr_c <= 0; c_active <= 0; c_phase <= 0; c_pending_blks <= 0; c_blk_cnt <= 0;
        end else begin
            if (a_block_done_pulse) c_pending_blks <= c_pending_blks + 1;
            
            if (!c_active) begin
                if (c_pending_blks > 0 && ptr_c != wr_ptr) begin
                    c_active <= 1; c_phase <= 0; c_blk_cnt <= 0;
                    c_pending_blks <= c_pending_blks - 1;
                end
            end else begin
                if (c_phase == CYCLE_PERIOD - 1) begin
                    c_phase <= 0; c_blk_cnt <= c_blk_cnt + 1;
                    if (c_blk_cnt == calc_blocks(task_c.val_m) - 1) begin
                        ptr_c <= ptr_c + 1; c_blk_cnt <= 0;
                        if (c_pending_blks == 0 && !a_block_done_pulse) c_active <= 0;
                    end else begin
                        if (c_pending_blks > 0) c_pending_blks <= c_pending_blks - 1;
                        else if (!a_block_done_pulse) c_active <= 0; // Should not happen
                    end
                end else c_phase <= c_phase + 1;
            end
        end
    end
    
    always_comb begin
        ctrl_rd_en_c = 0; ctrl_rd_addr_c = 0; ctrl_c_valid = 0; ctrl_vpu_mode = 3'b001;
        
        if (a_block_done_pulse && !c_active) begin
            ctrl_rd_en_c = 1; ctrl_rd_addr_c = cmd_mem[ptr_c[PTR_WIDTH-1:0]].addr_c;
        end
        
        if (c_active) begin
            if (c_phase < W) ctrl_c_valid = 1;
            if (c_phase < W - 1) begin
                ctrl_rd_en_c = 1;
                ctrl_rd_addr_c = task_c.addr_c + ADDR_WIDTH'(c_blk_cnt * W) + ADDR_WIDTH'(c_phase + 1);
            end else if (c_phase == W) begin
                ctrl_rd_en_c = 1;
                if (c_blk_cnt == calc_blocks(task_c.val_m) - 1) begin
                   if ((ptr_c + 1) != wr_ptr) ctrl_rd_addr_c = cmd_mem[(ptr_c[PTR_WIDTH-1:0]+1)].addr_c;
                end else ctrl_rd_addr_c = task_c.addr_c + ADDR_WIDTH'((c_blk_cnt + 1) * W);
            end
        end
    end


    // ============================================================
    // 7. Engine D (Monitor)
    // ============================================================
    // 逻辑: 计数 writeback，满了就 ptr_d++
    
    logic [31:0] d_rows_done;
    
    assign ctrl_row_mask = (task_d.val_m == 0) ? {W{1'b1}} : ((1 << task_d.val_m) - 1); 
    // 注意: Mask 应取自 task_a/b/c/d 中正在执行的那个? 
    // 实际上 Mask 应该跟随 VPU 输出，所以用 task_d 是最准确的 (当前正在输出的任务)

    // Col mask 同理
    assign ctrl_col_mask = {W{1'b1}}; // 假设 N 固定或未在指令中细化

    // D 地址逻辑
    always_ff @(posedge clk) begin
        if (rst) begin
            ptr_d <= 0; d_rows_done <= 0;
        end else begin
            if (core_writeback_valid) begin
                // 只有当 D 还有任务时才计数
                if (ptr_d != wr_ptr) begin
                    d_rows_done <= d_rows_done + 1;
                    
                    // 检查是否完成当前任务
                    if (d_rows_done == (task_d.val_m == 0 ? W : task_d.val_m) - 1) begin
                        ptr_d <= ptr_d + 1;
                        d_rows_done <= 0;
                    end
                end
            end
        end
    end
    
    // D 写地址 (简单累加，跨任务时复位由 ptr_d 变化隐式处理)
    // 为了支持连续地址，我们需要每次任务开始时加载 Base Addr
    logic [ADDR_WIDTH-1:0] d_curr_addr_offset;
    always_ff @(posedge clk) begin
        if (rst) d_curr_addr_offset <= 0;
        else if (core_writeback_valid) begin
            if (d_rows_done == (task_d.val_m == 0 ? W : task_d.val_m) - 1) d_curr_addr_offset <= 0;
            else d_curr_addr_offset <= d_curr_addr_offset + 1;
        end
    end
    assign ctrl_wr_addr_d = task_d.addr_d + d_curr_addr_offset;

endmodule
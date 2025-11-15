`timescale 1ns/1ps
`default_nettype none

/**
 * 模块名: control_unit
 * 功能: TPU 核心控制器 (Block Controller 版本)
 * 职责: 1. 通过 AXI-Lite 接收配置
 * 2. 按顺序 (Load, Compute, Drain, Writeback) 驱动 tpu_core
 * 3. 生成所有地址和时序信号
 * 4. 触发 AXI Master 回传
 */
module control_unit #(
    parameter int SYSTOLIC_ARRAY_WIDTH = 16,
    parameter int ADDR_WIDTH           = 10,  // Buffer 地址宽度
    parameter int CSR_ADDR_WIDTH       = 8    // 256 个 CSR 空间
)(
    input logic clk,
    input logic rst,

    // ========================================================================
    // 1. AXI-Lite Slave 接口 (来自 Host 的配置)
    // ========================================================================
    // (为简化，这里只列出关键信号。实际模块中应有 full AXI-Lite)
    input logic [CSR_ADDR_WIDTH-1:0] csr_addr,
    input logic                      csr_wr_en,
    input logic [31:0]               csr_wr_data,
    input logic                      csr_rd_en,
    output logic [31:0]              csr_rd_data,

    // ========================================================================
    // 2. AXI-Master 接口 (控制数据回传)
    // ========================================================================
    output logic                         axi_master_start_pulse, // 触发 Master
    output logic [31:0]                  axi_master_dest_addr, // DDR 目标地址
    output logic [ADDR_WIDTH-1:0]      axi_master_src_addr,  // Output Buffer 基地址
    output logic [15:0]                  axi_master_length,    // 传输长度 (M * N)
    input logic                          axi_master_done_irq,  // Master 完成中断

    // ========================================================================
    // 3. TPU Core 状态接口
    // ========================================================================
    input logic core_writeback_valid, // 来自 tpu_core, 标记 D[k] 已对齐

    // ========================================================================
    // 4. TPU Core 控制接口
    // ========================================================================
    // A-Flow (Input)
    output logic [ADDR_WIDTH-1:0] ctrl_rd_addr_a,
    output logic                  ctrl_rd_en_a,
    output logic                  ctrl_a_valid,
    output logic                  ctrl_a_switch,
    // B-Flow (Weight)
    output logic [ADDR_WIDTH-1:0] ctrl_rd_addr_b,
    output logic                  ctrl_rd_en_b,
    output logic                  ctrl_b_accept_w,
    output logic [$clog2(SYSTOLIC_ARRAY_WIDTH)-1:0] ctrl_b_weight_index,
    // C-Flow (Bias)
    output logic [ADDR_WIDTH-1:0] ctrl_rd_addr_c,
    output logic                  ctrl_rd_en_c,
    // D-Flow (Result)
    output logic [ADDR_WIDTH-1:0] ctrl_wr_addr_d,
    // Masks
    output logic [SYSTOLIC_ARRAY_WIDTH-1:0] ctrl_row_mask,
    output logic [SYSTOLIC_ARRAY_WIDTH-1:0] ctrl_col_mask,
    // VPU
    output logic [2:0]            ctrl_vpu_mode
);

    localparam W = SYSTOLIC_ARRAY_WIDTH;

    // --- CSR 地址映射 ---
    localparam ADDR_CONTROL      = 8'h00; // WO
    localparam ADDR_STATUS       = 8'h04; // RO
    localparam ADDR_DIM_M        = 8'h10; // R/W
    localparam ADDR_DIM_K        = 8'h14; // R/W
    localparam ADDR_DIM_N        = 8'h18; // R/W
    localparam ADDR_A            = 8'h20; // R/W
    localparam ADDR_B            = 8'h24; // R/W
    localparam ADDR_C            = 8'h28; // R/W
    localparam ADDR_D            = 8'h2C; // R/W
    localparam ADDR_DDR          = 8'h30; // R/W
    localparam ADDR_VPU_MODE     = 8'h34; // R/W
    localparam ADDR_LATENCY_C    = 8'h38; // R/W (VPU 延迟)
    localparam ADDR_LATENCY_D    = 8'h3C; // R/W (VPU + De-skew 延迟)

    // --- CSR 寄存器 ---
    logic [31:0] reg_dim_m, reg_dim_k, reg_dim_n;
    logic [ADDR_WIDTH-1:0] reg_addr_a, reg_addr_b, reg_addr_c, reg_addr_d;
    logic [31:0] reg_addr_ddr;
    logic [2:0]  reg_vpu_mode;
    logic [15:0] reg_latency_c, reg_latency_d;
    
    logic        reg_status_busy;
    logic        reg_status_done_pulse;
    logic        reg_control_start_pulse;

    // --- FSM 状态定义 ---
    typedef enum logic [3:0] {
        S_IDLE,
        S_LOAD_B,
        S_SWITCH_BUBBLE,
        S_COMPUTE,
        S_DRAIN,
        S_WRITEBACK_START,
        S_WRITEBACK_WAIT,
        S_DONE
    } fsm_state_e;
    
    fsm_state_e fsm_state, fsm_next_state;

    // --- AGU 计数器 ---
    logic [$clog2(W)-1:0]       i_cnt_b; // K
    logic [15:0]                k_cnt_a; // M
    logic [15:0]                k_cnt_c; // M
    logic [15:0]                k_cnt_d; // M
    logic [15:0]                delay_cnt_c;
    logic [15:0]                delay_cnt_d;

    // --- AGU 状态 ---
    logic agu_b_done;
    logic agu_a_done;
    logic agu_d_done;
    logic c_is_active;
    logic d_is_active;

    // ========================================================================
    // 1. CSR 寄存器堆 (AXI-Lite R/W)
    // ========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            reg_dim_m <= '0; reg_dim_k <= '0; reg_dim_n <= '0;
            reg_addr_a <= '0; reg_addr_b <= '0; reg_addr_c <= '0; reg_addr_d <= '0;
            reg_addr_ddr <= '0; reg_vpu_mode <= '0;
            reg_latency_c <= '0; reg_latency_d <= '0;
            reg_status_done_pulse <= '0;
            reg_control_start_pulse <= '0;
        end else begin
            // 脉冲信号自动清零
            if (reg_control_start_pulse) reg_control_start_pulse <= 1'b0;
            if (reg_status_done_pulse)   reg_status_done_pulse <= 1'b0;

            if (csr_wr_en) begin
                case (csr_addr)
                    ADDR_CONTROL:    if (csr_wr_data[0]) reg_control_start_pulse <= 1'b1;
                    ADDR_DIM_M:      reg_dim_m     <= csr_wr_data;
                    ADDR_DIM_K:      reg_dim_k     <= csr_wr_data;
                    ADDR_DIM_N:      reg_dim_n     <= csr_wr_data;
                    ADDR_A:          reg_addr_a    <= csr_wr_data[ADDR_WIDTH-1:0];
                    ADDR_B:          reg_addr_b    <= csr_wr_data[ADDR_WIDTH-1:0];
                    ADDR_C:          reg_addr_c    <= csr_wr_data[ADDR_WIDTH-1:0];
                    ADDR_D:          reg_addr_d    <= csr_wr_data[ADDR_WIDTH-1:0];
                    ADDR_DDR:        reg_addr_ddr  <= csr_wr_data;
                    ADDR_VPU_MODE:   reg_vpu_mode  <= csr_wr_data[2:0];
                    ADDR_LATENCY_C:  reg_latency_c <= csr_wr_data[15:0];
                    ADDR_LATENCY_D:  reg_latency_d <= csr_wr_data[15:0];
                    default: ;
                endcase
            end
        end
    end
    
    // CSR 读 Mux
    always_comb begin
        case (csr_addr)
            ADDR_STATUS:     csr_rd_data = {30'b0, reg_status_done_pulse, reg_status_busy};
            ADDR_DIM_M:      csr_rd_data = reg_dim_m;
            // ... (省略其他寄存器的读逻辑) ...
            default:         csr_rd_data = 32'hDEADBEEF; // Error
        endcase
    end
    
    // ========================================================================
    // 2. FSM (状态机)
    // ========================================================================
    
    // FSM 状态寄存器
    always_ff @(posedge clk) begin
        if (rst) fsm_state <= S_IDLE;
        else     fsm_state <= fsm_next_state;
    end
    
    assign reg_status_busy = (fsm_state != S_IDLE);

    // FSM 状态转移
    always_comb begin
        fsm_next_state = fsm_state;
        case (fsm_state)
            S_IDLE:             if (reg_control_start_pulse) fsm_next_state = S_LOAD_B;
            S_LOAD_B:           if (agu_b_done)              fsm_next_state = S_SWITCH_BUBBLE;
            S_SWITCH_BUBBLE:    fsm_next_state = S_COMPUTE;
            S_COMPUTE:          if (agu_a_done)              fsm_next_state = S_DRAIN;
            S_DRAIN:            if (agu_d_done)              fsm_next_state = S_WRITEBACK_START;
            S_WRITEBACK_START:  fsm_next_state = S_WRITEBACK_WAIT;
            S_WRITEBACK_WAIT:   if (axi_master_done_irq)     fsm_next_state = S_DONE;
            S_DONE:             fsm_next_state = S_IDLE;
        endcase
    end
    
    // FSM 输出 (用于 AGU 使能)
    logic fsm_load_b_en, fsm_compute_en, fsm_wb_start_en;
    always_comb begin
        fsm_load_b_en   = (fsm_state == S_LOAD_B);
        fsm_compute_en  = (fsm_state == S_COMPUTE);
        fsm_wb_start_en = (fsm_state == S_WRITEBACK_START);
    end

    // ========================================================================
    // 3. AGUs (地址生成单元)
    // ========================================================================

    // --- AGU-B (Weight) ---
    always_ff @(posedge clk) begin
        if (rst || fsm_state == S_IDLE) i_cnt_b <= '0;
        else if (fsm_load_b_en && !agu_b_done) i_cnt_b <= i_cnt_b + 1;
    end
    assign agu_b_done = fsm_load_b_en && (i_cnt_b == reg_dim_k - 1);
    assign ctrl_rd_addr_b      = reg_addr_b + i_cnt_b;
    assign ctrl_rd_en_b        = fsm_load_b_en;
    assign ctrl_b_accept_w     = fsm_load_b_en;
    assign ctrl_b_weight_index = i_cnt_b;

    // --- AGU-A (Input) ---
    always_ff @(posedge clk) begin
        if (rst || fsm_state == S_IDLE) k_cnt_a <= '0;
        else if (fsm_compute_en && !agu_a_done) k_cnt_a <= k_cnt_a + 1;
    end
    assign agu_a_done = fsm_compute_en && (k_cnt_a == reg_dim_m - 1);
    assign ctrl_rd_addr_a = reg_addr_a + k_cnt_a;
    assign ctrl_rd_en_a   = fsm_compute_en;
    assign ctrl_a_valid   = fsm_compute_en;

    // --- AGU-C (Bias) ---
    always_ff @(posedge clk) begin
        if (rst || fsm_state == S_IDLE) begin
            delay_cnt_c <= '0;
            k_cnt_c     <= '0;
            c_is_active <= '0;
        end else if (fsm_compute_en) begin
            if (delay_cnt_c < reg_latency_c) begin
                delay_cnt_c <= delay_cnt_c + 1; // 等待 L_base 延迟
            end else begin
                c_is_active <= 1'b1; // 延迟结束，启动 C-Flow
            end
            if (c_is_active && k_cnt_c < reg_dim_m) begin
                k_cnt_c <= k_cnt_c + 1; // 线性计数
            end
        end else begin // COMPUTE 状态结束，清零
            delay_cnt_c <= '0;
            k_cnt_c     <= '0;
            c_is_active <= '0;
        end
    end
    assign ctrl_rd_addr_c = reg_addr_c + k_cnt_c;
    assign ctrl_rd_en_c   = c_is_active;

    // --- AGU-D (Writeback Addr) ---
    always_ff @(posedge clk) begin
        if (rst || fsm_state == S_IDLE) begin
            delay_cnt_d <= '0;
            k_cnt_d     <= '0;
            d_is_active <= '0;
        end else if (fsm_compute_en || fsm_state == S_DRAIN) begin
            if (delay_cnt_d < reg_latency_d) begin
                delay_cnt_d <= delay_cnt_d + 1; // 等待 L_total 延迟
            end else begin
                d_is_active <= 1'b1; // 延迟结束，启动地址
            end
            if (d_is_active && k_cnt_d < reg_dim_m) begin
                // 只有当 tpu_core 确认数据已对齐，才增加地址
                if (core_writeback_valid) k_cnt_d <= k_cnt_d + 1;
            end
        end else begin
            delay_cnt_d <= '0;
            k_cnt_d     <= '0;
            d_is_active <= '0;
        end
    end
    assign ctrl_wr_addr_d = reg_addr_d + k_cnt_d;
    assign agu_d_done = d_is_active && (k_cnt_d == reg_dim_m);

    // ========================================================================
    // 4. 控制信号输出 (直连)
    // ========================================================================
    assign ctrl_a_switch = (fsm_state == S_SWITCH_BUBBLE);
    assign ctrl_vpu_mode = reg_vpu_mode;

    // --- Mask Generation ---
    genvar i_mask;
    generate
        for (i_mask = 0; i_mask < W; i_mask++) begin : mask_gen
            assign ctrl_row_mask[i_mask] = (i_mask < reg_dim_k);
            assign ctrl_col_mask[i_mask] = (i_mask < reg_dim_n);
        end
    endgenerate

    // --- AXI Master Control ---
    assign axi_master_start_pulse = fsm_wb_start_en;
    assign axi_master_src_addr    = reg_addr_d;
    assign axi_master_dest_addr   = reg_addr_ddr;
    assign axi_master_length      = reg_dim_m * reg_dim_n; // 总元素个数
    
    // --- DONE Pulse Generation ---
    always_ff @(posedge clk) begin
        if (fsm_next_state == S_DONE && fsm_state != S_DONE) begin
            reg_status_done_pulse <= 1'b1;
        end
    end

endmodule
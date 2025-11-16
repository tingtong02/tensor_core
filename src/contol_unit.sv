`timescale 1ns/1ps
`default_nettype none

/**
 * 模块名: control_unit (已修正)
 * 架构: 严格的 W 周期流水线
 * * FSM 严格按照 W 周期 (SYSTOLIC_ARRAY_WIDTH) 切换,
 * 通过掩码 (Masking) 控制 m,k < W 时的实际读写使能。
 * * S_PRELOAD_B:   [W 周期] 加载 B1
 * S_SWITCH_BUBBLE: [1 周期] 切换 B1, 复位 A/B AGU
 * S_RUN_COMPUTE:   [W 周期] 计算 A*B1, 同时加载 B2
 * S_DRAIN:         [M 周期] 等待 D[m-1] 写回
 */
module control_unit #(
    parameter int SYSTOLIC_ARRAY_WIDTH = 16,
    parameter int ADDR_WIDTH           = 10,
    parameter int CSR_ADDR_WIDTH       = 8
)(
    input logic clk,
    input logic rst,

    // ========================================================================
    // 1. AXI-Lite Slave 接口 (不变)
    // ========================================================================
    input logic [CSR_ADDR_WIDTH-1:0] csr_addr,
    input logic                      csr_wr_en,
    input logic [31:0]               csr_wr_data,
    input logic                      csr_rd_en,
    output logic [31:0]              csr_rd_data,

    // ========================================================================
    // 2. AXI-Master 接口 (不变)
    // ========================================================================
    output logic                         axi_master_start_pulse,
    output logic [31:0]                  axi_master_dest_addr,
    output logic [ADDR_WIDTH-1:0]      axi_master_src_addr,
    output logic [15:0]                  axi_master_length,
    input logic                          axi_master_done_irq,

    // ========================================================================
    // 3. TPU Core 状态接口 (不变)
    // ========================================================================
    input logic core_writeback_valid,

    // ========================================================================
    // 4. TPU Core 控制接口 (不变)
    // ========================================================================
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
    output logic [ADDR_WIDTH-1:0] ctrl_wr_addr_d,
    output logic [SYSTOLIC_ARRAY_WIDTH-1:0] ctrl_row_mask,
    output logic [SYSTOLIC_ARRAY_WIDTH-1:0] ctrl_col_mask,
    output logic [2:0]            ctrl_vpu_mode
);
    localparam W = SYSTOLIC_ARRAY_WIDTH;
    // 计数器宽度 (e.g., 16 -> 4 bits)
    localparam W_WIDTH = $clog2(W);

    // --- CSR 地址映射 (不变) ---
    localparam ADDR_CONTROL      = 8'h00;
    localparam ADDR_STATUS       = 8'h04;
    localparam ADDR_DIM_M        = 8'h10;
    localparam ADDR_DIM_K        = 8'h14;
    localparam ADDR_DIM_N        = 8'h18;
    localparam ADDR_A            = 8'h20;
    localparam ADDR_B            = 8'h24;
    localparam ADDR_C            = 8'h28;
    localparam ADDR_D            = 8'h2C;
    localparam ADDR_DDR          = 8'h30;
    localparam ADDR_VPU_MODE     = 8'h34;
    localparam ADDR_LATENCY_C    = 8'h38;
    localparam ADDR_LATENCY_D    = 8'h3C;

    // --- CSR 寄存器 (不变) ---
    logic [31:0] reg_dim_m, reg_dim_k, reg_dim_n;
    logic [ADDR_WIDTH-1:0] reg_addr_a, reg_addr_b, reg_addr_c, reg_addr_d;
    logic [31:0] reg_addr_ddr;
    logic [2:0]  reg_vpu_mode;
    logic [15:0] reg_latency_c, reg_latency_d;
    logic        reg_status_busy;
    logic        reg_status_done_pulse;
    logic        reg_control_start_pulse;

    // ========================================================================
    // 1. CSR 寄存器堆 (已修复 DONE 脉冲逻辑)
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

            // FSM 进入 S_DONE 时置位脉冲
            if (fsm_next_state == S_DONE && fsm_state != S_DONE) begin
                reg_status_done_pulse <= 1'b1;
            end

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
    
    // CSR 读 Mux (不变)
    always_comb begin
        case (csr_addr)
            ADDR_STATUS:     csr_rd_data = {30'b0, reg_status_done_pulse, reg_status_busy};
            ADDR_DIM_M:      csr_rd_data = reg_dim_m;
            ADDR_DIM_K:      csr_rd_data = reg_dim_k;
            ADDR_DIM_N:      csr_rd_data = reg_dim_n;
            // (省略其他, 保持与原文件一致)
            default:         csr_rd_data = 32'hDEADBEEF;
        endcase
    end
    
    // ========================================================================
    // 2. FSM (状态机) - (已修正: W 周期流水线)
    // ========================================================================
    
    typedef enum logic [3:0] {
        S_IDLE,
        S_PRELOAD_B,        // 状态: 预加载 B1 (K 周期)
        S_SWITCH_BUBBLE,    // 状态: 切换 B1 (1 周期)
        S_RUN_COMPUTE,      // 状态: 计算 A*B1 + C1, 同时加载 B2 (M 周期)
        S_DRAIN,            // 状态: 排空 A*B1 的 Psum
        S_WRITEBACK_START,
        S_WRITEBACK_WAIT,
        S_DONE
    } fsm_state_e;
    
    fsm_state_e fsm_state, fsm_next_state;

    // --- AGU 计数器 (已修正) ---
    // 计数器 *始终* 运行 W 周期 (0 to W-1)
    logic [W_WIDTH-1:0] i_cnt_b; // B (Weight) 计数器
    logic [W_WIDTH-1:0] k_cnt_a; // A (Input) 计数器
    logic [W_WIDTH-1:0] k_cnt_c; // C (Bias) 计数器 (跟随 A)
    
    // D 计数器必须是 M-based, 因为它由 valid 脉冲驱动
    logic [15:0]        m_cnt_d; // D (Result) 计数器 (使用 16-bit 匹配原设计 [cite: 87])
    
    logic [15:0] delay_cnt_c;
    logic [15:0] delay_cnt_d;

    // --- AGU 状态 (已修正) ---
    logic agu_b_done; // B 运行 W 周期完成
    logic agu_a_done; // A 运行 W 周期完成
    logic agu_d_done; // D 排空 M 周期完成
    logic c_is_active;
    logic d_is_active;

    // FSM 状态寄存器
    always_ff @(posedge clk) begin
        if (rst) fsm_state <= S_IDLE;
        else     fsm_state <= fsm_next_state;
    end
    
    assign reg_status_busy = (fsm_state != S_IDLE);

    // FSM 状态转移 (已修正)
    always_comb begin
        fsm_next_state = fsm_state;
        case (fsm_state)
            S_IDLE:             if (reg_control_start_pulse) fsm_next_state = S_PRELOAD_B;
            S_PRELOAD_B:        if (agu_b_done)              fsm_next_state = S_SWITCH_BUBBLE;
            S_SWITCH_BUBBLE:    fsm_next_state = S_RUN_COMPUTE;
            S_RUN_COMPUTE:      if (agu_a_done)              fsm_next_state = S_DRAIN;
            S_DRAIN:            if (agu_d_done)              fsm_next_state = S_WRITEBACK_START;
            S_WRITEBACK_START:  fsm_next_state = S_WRITEBACK_WAIT;
            S_WRITEBACK_WAIT:   if (axi_master_done_irq)     fsm_next_state = S_DONE;
            S_DONE:             fsm_next_state = S_IDLE;
        endcase
    end
    
    // FSM 输出 (用于 AGU 使能) (已修正)
    logic fsm_b_load_en;
    logic fsm_a_compute_en;
    logic fsm_c_d_en;
    logic fsm_wb_start_en;

    always_comb begin
        // ** 核心流水线逻辑 **
        fsm_b_load_en    = (fsm_state == S_PRELOAD_B) || (fsm_state == S_RUN_COMPUTE);
        fsm_a_compute_en = (fsm_state == S_RUN_COMPUTE);
        fsm_c_d_en       = (fsm_state == S_RUN_COMPUTE) || (fsm_state == S_DRAIN);
        fsm_wb_start_en  = (fsm_state == S_WRITEBACK_START);
    end

    // ========================================================================
    // 3. AGUs (地址生成单元) - (已修正: W 周期 + 掩码)
    // ========================================================================

    // --- AGU-B (Weight) ---
    // 计数器 *始终* 运行 W 周期
    always_ff @(posedge clk) begin
        if (rst || fsm_state == S_IDLE) begin
            i_cnt_b <= '0;
        // 在 SWITCH 状态复位, 为 S_RUN_COMPUTE (加载 B2) 做准备
        end else if (fsm_state == S_SWITCH_BUBBLE) begin
             i_cnt_b <= '0;
        end else if (fsm_b_load_en) begin
            if (i_cnt_b == W-1) i_cnt_b <= '0; // 自动回滚
            else                i_cnt_b <= i_cnt_b + 1;
        end
    end
    
    // FSM 切换信号: 必须在第 W 拍 (W-1) 产生
    assign agu_b_done = fsm_b_load_en && (i_cnt_b == W-1);

    // 掩码使能: 仅在 i < K 时才真正读内存和发送 accept
    wire b_is_active = (i_cnt_b < reg_dim_k[W_WIDTH-1:0]);

    assign ctrl_rd_addr_b      = reg_addr_b + i_cnt_b;
    assign ctrl_rd_en_b        = fsm_b_load_en && b_is_active;
    assign ctrl_b_accept_w     = fsm_b_load_en && b_is_active;
    assign ctrl_b_weight_index = i_cnt_b;

    // --- AGU-A (Input) ---
    // 计数器 *始终* 运行 W 周期
    always_ff @(posedge clk) begin
        if (rst || fsm_state == S_IDLE) begin
            k_cnt_a <= '0;
        // 在 SWITCH 状态复位, 为 S_RUN_COMPUTE (计算 A) 做准备
        end else if (fsm_state == S_SWITCH_BUBBLE) begin
            k_cnt_a <= '0;
        end else if (fsm_a_compute_en) begin
            if (k_cnt_a == W-1) k_cnt_a <= '0; // 自动回滚
            else                k_cnt_a <= k_cnt_a + 1;
        end
    end
    
    // FSM 切换信号: 必须在第 W 拍 (W-1) 产生
    assign agu_a_done = fsm_a_compute_en && (k_cnt_a == W-1);

    // 掩码使能: 仅在 k < M 时才真正读内存和发送 valid
    wire a_is_active = (k_cnt_a < reg_dim_m[W_WIDTH-1:0]);

    assign ctrl_rd_addr_a = reg_addr_a + k_cnt_a;
    assign ctrl_rd_en_a   = fsm_a_compute_en && a_is_active;
    assign ctrl_a_valid   = fsm_a_compute_en && a_is_active;
    
    // --- AGU-C (Bias) ---
    // 计数器 *跟随* AGU-A (k_cnt_a)
    always_ff @(posedge clk) begin
        if (rst || fsm_state == S_IDLE) begin
            delay_cnt_c <= '0;
            k_cnt_c     <= '0;
            c_is_active <= '0;
        end else if (fsm_c_d_en) begin
            if (delay_cnt_c < reg_latency_c) begin
                delay_cnt_c <= delay_cnt_c + 1;
            end else begin
                c_is_active <= 1'b1;
            end
            
            // C 的地址必须与 A 的地址同步
            k_cnt_c <= k_cnt_a;
            
        end else begin // IDLE 或 PRELOAD
            delay_cnt_c <= '0;
            k_cnt_c     <= '0;
            c_is_active <= '0;
        end
    end
    assign ctrl_rd_addr_c = reg_addr_c + k_cnt_c;
    // 使能: 必须 C 激活 且 A 也在激活 (a_is_active)
    assign ctrl_rd_en_c   = c_is_active && a_is_active;

    // --- AGU-D (Writeback Addr) ---
    // 计数器 *必须* 按 M 运行, 由 core_writeback_valid 驱动
    always_ff @(posedge clk) begin
        if (rst || fsm_state == S_IDLE) begin
            delay_cnt_d <= '0;
            m_cnt_d     <= '0;
            d_is_active <= '0;
        end else if (fsm_c_d_en) begin
            if (delay_cnt_d < reg_latency_d) begin
                delay_cnt_d <= delay_cnt_d + 1;
            end else begin
                d_is_active <= 1'b1;
            end
            
            if (d_is_active && (m_cnt_d < reg_dim_m)) begin
                // 只有当 tpu_core 确认 D[k] 已对齐, 才增加地址
                if (core_writeback_valid) begin
                    m_cnt_d <= m_cnt_d + 1;
                end
            end
        end else begin
            delay_cnt_d <= '0;
            m_cnt_d     <= '0;
            d_is_active <= '0;
        end
    end
    assign ctrl_wr_addr_d = reg_addr_d + m_cnt_d;
    // 切换: 必须在第 M 拍 (m_cnt_d == reg_dim_m) 产生
    assign agu_d_done = d_is_active && (m_cnt_d == reg_dim_m);

    // ========================================================================
    // 4. 控制信号输出 (直连)
    // ========================================================================
    assign ctrl_a_switch = (fsm_state == S_SWITCH_BUBBLE);
    assign ctrl_vpu_mode = reg_vpu_mode;

    // --- Mask Generation (K/N 维度掩码) ---
    genvar i_mask;
    generate
        for (i_mask = 0; i_mask < W; i_mask++) begin : mask_gen
            // 'K' 维度 (行掩码) [cite: 266]
            assign ctrl_row_mask[i_mask] = (i_mask < reg_dim_k);
            // 'N' 维度 (列掩码) [cite: 267]
            assign ctrl_col_mask[i_mask] = (i_mask < reg_dim_n);
        end
    endgenerate

    // --- AXI Master Control (不变) ---
    assign axi_master_start_pulse = fsm_wb_start_en;
    assign axi_master_src_addr    = reg_addr_d;
    assign axi_master_dest_addr   = reg_addr_ddr;
    assign axi_master_length      = reg_dim_m * reg_dim_n;
    
endmodule
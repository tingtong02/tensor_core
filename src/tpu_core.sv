`timescale 1ns/1ps
`default_nettype none

/**
 * 模块名: tpu_core
 * 功能: TPU 核心数据通路 (Datapath Core)
 * 包含: Input/Output Buffers, Skew Logic, Systolic Array, VPU, De-skew Logic
 * 职责: 负责数据的流动、时序对齐和运算。不包含 FSM。
 */
module tpu_core #(
    parameter int SYSTOLIC_ARRAY_WIDTH = 16,
    parameter int DATA_WIDTH_IN        = 8,   // Systolic 输入位宽 (int8)
    parameter int DATA_WIDTH_ACCUM     = 32,  // 累加/VPU/Buffer 位宽 (int32)
    parameter int ADDR_WIDTH           = 10   // Buffer 地址深度
)(
    input logic clk,
    input logic rst,

    // ========================================================================
    // 1. Host 接口 (写入 Input Buffer)
    // ========================================================================
    input logic [ADDR_WIDTH-1:0]       host_wr_addr_in,
    input logic                        host_wr_en_in,
    input logic [DATA_WIDTH_ACCUM-1:0] host_wr_data_in [SYSTOLIC_ARRAY_WIDTH],

    // ========================================================================
    // 2. AXI Master 接口 (读取 Output Buffer)
    // ========================================================================
    input logic [ADDR_WIDTH-1:0]       axim_rd_addr_in,
    input logic                        axim_rd_en_in,
    output logic [DATA_WIDTH_ACCUM-1:0] axim_rd_data_out [SYSTOLIC_ARRAY_WIDTH],

    // ========================================================================
    // 3. Control Unit 接口 (控制信号)
    // ========================================================================
    
    // --- 读 Input Buffer (A, B, C) ---
    input logic [ADDR_WIDTH-1:0] ctrl_rd_addr_a,
    input logic                  ctrl_rd_en_a,
    input logic [ADDR_WIDTH-1:0] ctrl_rd_addr_b,
    input logic                  ctrl_rd_en_b,
    input logic [ADDR_WIDTH-1:0] ctrl_rd_addr_c,
    input logic                  ctrl_rd_en_c,
    
    // --- 写 Output Buffer (D) ---
    input logic [ADDR_WIDTH-1:0] ctrl_wr_addr_d, 
    
    // --- Systolic 控制 ---
    input logic                  ctrl_accept_w,     // A-Flow 全局 Accept
    input logic [$clog2(SYSTOLIC_ARRAY_WIDTH)-1:0] ctrl_weight_index, // A-Flow 全局 Index
    input logic                  ctrl_sys_valid,    // B-Flow 全局 Valid
    input logic                  ctrl_sys_switch,   // B-Flow 全局 Switch
    input logic [SYSTOLIC_ARRAY_WIDTH-1:0] ctrl_row_mask,   // K 维度
    input logic [SYSTOLIC_ARRAY_WIDTH-1:0] ctrl_col_mask,   // M 维度

    // --- VPU 控制 ---
    input logic [2:0]            ctrl_vpu_mode,

    // ========================================================================
    // 4. 状态输出 (给 Control Unit)
    // ========================================================================
    // 当一整行对齐的 VPU 结果准备好写入 Output Buffer 时，脉冲 1 拍
    output logic core_writeback_valid 
);

    localparam W = SYSTOLIC_ARRAY_WIDTH;

    // --- 内部连线: Input Buffer 读出 ---
    logic [DATA_WIDTH_ACCUM-1:0] ib_rd_a [W];
    logic [DATA_WIDTH_ACCUM-1:0] ib_rd_b [W];
    logic [DATA_WIDTH_ACCUM-1:0] ib_rd_c [W];

    // --- 内部连线: 截断 (32b -> 8b) ---
    logic signed [DATA_WIDTH_IN-1:0] sys_in_a_raw [W];
    logic signed [DATA_WIDTH_IN-1:0] sys_in_b_raw [W];

    // --- 内部连线: 倾斜 (Skew) ---
    logic signed [DATA_WIDTH_IN-1:0] sys_in_a_skewed [W];
    logic        [$clog2(W)-1:0]     sys_idx_skewed  [W];
    logic                            sys_acc_skewed  [W];

    logic signed [DATA_WIDTH_IN-1:0] sys_in_b_skewed [W];
    logic                            sys_val_skewed  [W];
    logic                            sys_sw_skewed   [W];

    // --- 内部连线: Systolic -> VPU ---
    logic signed [DATA_WIDTH_ACCUM-1:0] sys_out_data [W];
    logic                               sys_out_valid [W];

    // --- 内部连线: VPU -> De-skew ---
    logic signed [DATA_WIDTH_ACCUM-1:0] vpu_out_data [W];
    logic                               vpu_out_valid [W];

    // --- 内部连线: De-skew -> Output Buffer ---
    logic signed [DATA_WIDTH_ACCUM-1:0] aligned_wr_data [W];
    logic                               aligned_wr_valid;

    // ========================================================================
    // 模块 1: Input Buffer
    // ========================================================================
    input_buffer #(
        .DATA_WIDTH(DATA_WIDTH_ACCUM),
        .SYSTOLIC_ARRAY_WIDTH(W),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) ib_inst (
        .clk(clk),
        
        // Host 写
        .host_wr_addr(host_wr_addr_in),
        .host_wr_en(host_wr_en_in),
        .host_wr_data(host_wr_data_in),

        // CU 读 A (Weight)
        .rd_addr_a(ctrl_rd_addr_a), .rd_en_a(ctrl_rd_en_a), .rd_data_a(ib_rd_a),
        // CU 读 B (Input)
        .rd_addr_b(ctrl_rd_addr_b), .rd_en_b(ctrl_rd_en_b), .rd_data_b(ib_rd_b),
        // CU 读 C (Bias)
        .rd_addr_c(ctrl_rd_addr_c), .rd_en_c(ctrl_rd_en_c), .rd_data_c(ib_rd_c)
    );

    // ========================================================================
    // 模块 2: Output Buffer
    // ========================================================================
    output_buffer #(
        .DATA_WIDTH(DATA_WIDTH_ACCUM),
        .SYSTOLIC_ARRAY_WIDTH(W),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) ob_inst (
        .clk(clk),
        
        // VPU 写
        .wr_addr(ctrl_wr_addr_d),       // 地址来自 CU
        .wr_en(aligned_wr_valid),       // 使能来自 De-skew
        .wr_data(aligned_wr_data),      // 数据来自 De-skew
        
        // AXI Master 读
        .rd_addr(axim_rd_addr_in),
        .rd_en(axim_rd_en_in),
        .rd_data(axim_rd_data_out)
    );
    
    // ========================================================================
    // 逻辑 3: 输入截断 (32-bit to 8-bit)
    // ========================================================================
    genvar i_tr;
    generate
        for (i_tr = 0; i_tr < W; i_tr++) begin : trunc_gen
            // UB 输出 32位，Systolic 输入 8位，取低8位 [7:0]
            assign sys_in_a_raw[i_tr] = ib_rd_a[i_tr][DATA_WIDTH_IN-1:0];
            assign sys_in_b_raw[i_tr] = ib_rd_b[i_tr][DATA_WIDTH_IN-1:0];
        end
    endgenerate

    // ========================================================================
    // 逻辑 4: Skew Buffers (关键时序对齐)
    // ========================================================================
    genvar i, j, k;
    generate
        // --- A-Flow Skew (Top Inputs) ---
        // 第 j 列延迟 j 个周期
        for (j = 0; j < W; j++) begin : a_skew_gen
            if (j == 0) begin
                // 第 0 列不延迟
                assign sys_in_a_skewed[0] = sys_in_a_raw[0];
                assign sys_idx_skewed[0]  = ctrl_weight_index;
                assign sys_acc_skewed[0]  = ctrl_accept_w;
            end else begin
                // 定义 j 级深的移位寄存器
                logic signed [DATA_WIDTH_IN-1:0] delay_data [j];
                logic [$clog2(W)-1:0]            delay_idx  [j];
                logic                            delay_acc  [j];

                always_ff @(posedge clk) begin
                    if (rst) begin
                        for(int d=0; d<j; d++) begin
                            delay_data[d] <= '0'; delay_idx[d] <= '0'; delay_acc[d] <= '0';
                        end
                    end else begin
                        delay_data[0] <= sys_in_a_raw[j];
                        delay_idx[0]  <= ctrl_weight_index;
                        delay_acc[0]  <= ctrl_accept_w;
                        for(int d=1; d<j; d++) begin
                            delay_data[d] <= delay_data[d-1];
                            delay_idx[d]  <= delay_idx[d-1];
                            delay_acc[d]  <= delay_acc[d-1];
                        end
                    end
                end
                // 链尾输出
                assign sys_in_a_skewed[j] = delay_data[j-1];
                assign sys_idx_skewed[j]  = delay_idx[j-1];
                assign sys_acc_skewed[j]  = delay_acc[j-1];
            end
        end

        // --- B-Flow Skew (Left Inputs) ---
        // 第 i 行延迟 i 个周期
        for (i = 0; i < W; i++) begin : b_skew_gen
            if (i == 0) begin
                assign sys_in_b_skewed[0] = sys_in_b_raw[0];
                assign sys_val_skewed[0]  = ctrl_sys_valid;
                assign sys_sw_skewed[0]   = ctrl_sys_switch;
            end else begin
                logic signed [DATA_WIDTH_IN-1:0] delay_data [i];
                logic                            delay_val  [i];
                logic                            delay_sw   [i];

                always_ff @(posedge clk) begin
                    if (rst) begin
                        for(int d=0; d<i; d++) begin
                            delay_data[d] <= '0'; delay_val[d] <= '0'; delay_sw[d] <= '0';
                        end
                    end else begin
                        delay_data[0] <= sys_in_b_raw[i];
                        delay_val[0]  <= ctrl_sys_valid;
                        delay_sw[0]   <= ctrl_sys_switch;
                        for(int d=1; d<i; d++) begin
                            delay_data[d] <= delay_data[d-1];
                            delay_val[d]  <= delay_val[d-1];
                            delay_sw[d]   <= delay_sw[d-1];
                        end
                    end
                end
                assign sys_in_b_skewed[i] = delay_data[i-1];
                assign sys_val_skewed[i]  = delay_val[i-1];
                assign sys_sw_skewed[i]   = delay_sw[i-1];
            end
        end
    endgenerate

    // ========================================================================
    // 模块 5: Systolic Array
    // ========================================================================
    systolic #(
        .SYSTOLIC_ARRAY_WIDTH(W),
        .DATA_WIDTH_IN(DATA_WIDTH_IN),
        .DATA_WIDTH_ACCUM(DATA_WIDTH_ACCUM)
    ) sys_inst (
        .clk(clk),
        .rst(rst),
        // A-Flow
        .sys_weight_in(sys_in_a_skewed),
        .sys_index_in(sys_idx_skewed),
        .sys_accept_w_in(sys_acc_skewed),
        // B-Flow
        .sys_data_in(sys_in_b_skewed),
        .sys_valid_in(sys_val_skewed),
        .sys_switch_in(sys_sw_skewed),
        // Controls
        .sys_enable_rows(ctrl_row_mask),
        .sys_enable_cols(ctrl_col_mask),
        // Output
        .sys_data_out(sys_out_data),
        .sys_valid_out(sys_out_valid)
    );

    // ========================================================================
    // 模块 6: VPU (Vector Processing Unit)
    // ========================================================================
    vpu #(
        .VPU_WIDTH(W),
        .DATA_WIDTH_IN(DATA_WIDTH_ACCUM)
    ) vpu_inst (
        .clk(clk),
        .rst(rst),
        .vpu_mode(ctrl_vpu_mode),
        // 来自 Systolic 的输入
        .vpu_sys_data_in(sys_out_data),
        .vpu_sys_valid_in(sys_out_valid),
        // 来自 Input Buffer 的 Bias
        .vpu_bias_data_in(ib_rd_c),
        // 输出 (未对齐)
        .vpu_data_out(vpu_out_data),
        .vpu_valid_out(vpu_out_valid)
    );

    // ========================================================================
    // 逻辑 7: Output De-skew Logic (输出对齐)
    // ========================================================================
    // 目标: 将 VPU "梯形"输出拉平为"矩形"
    // 策略: 第 j 列延迟 (W - 1 - j) 拍
    
    logic [W-1:0] aligned_valid_pipe; // 用于 AND 规约
    
    genvar i_dsk;
    generate
        for (i_dsk = 0; i_dsk < W; i_dsk++) begin : deskew_gen
            localparam int DELAY = (W - 1) - i_dsk;

            if (DELAY == 0) begin
                // 最后一列 (j=15): 不延迟，作为基准
                assign aligned_wr_data[i_dsk]    = vpu_out_data[i_dsk];
                assign aligned_valid_pipe[i_dsk] = vpu_out_valid[i_dsk];
            end else begin
                // 其他列 (j < 15): 创建深度为 DELAY 的移位寄存器
                logic signed [DATA_WIDTH_ACCUM-1:0] pipe_data [DELAY];
                logic                               pipe_valid [DELAY];
                
                always_ff @(posedge clk) begin
                    if (rst) begin
                        for(int d=0; d<DELAY; d++) begin
                            pipe_data[d]  <= '0;
                            pipe_valid[d] <= '0;
                        end
                    end else begin
                        // 链头
                        pipe_data[0]  <= vpu_out_data[i_dsk];
                        pipe_valid[0] <= vpu_out_valid[i_dsk];
                        // 链中间移位
                        for(int d=1; d<DELAY; d++) begin
                            pipe_data[d]  <= pipe_data[d-1];
                            pipe_valid[d] <= pipe_valid[d-1];
                        end
                    end
                end
                // 链尾输出
                assign aligned_wr_data[i_dsk]    = pipe_data[DELAY-1];
                assign aligned_valid_pipe[i_dsk] = pipe_valid[DELAY-1];
            end
        end
    endgenerate

    // 生成最终的写使能: 必须所有列的数据都已对齐且有效
    assign aligned_wr_valid = &aligned_valid_pipe; // AND-Reduction
    
    // 向 CU 报告一个脉冲
    assign core_writeback_valid = aligned_wr_valid;

endmodule
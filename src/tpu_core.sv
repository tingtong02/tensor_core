`timescale 1ns/1ps
`default_nettype none

/**
 * 模块名: tpu_core
 * 功能: TPU 核心数据通路 (Datapath Core) - Modified
 * 修改: 
 * 1. 增加了 C-Flow (Bias) 的 Valid 信号通路，确保 Bias 数据与 Psum 数据在 VPU 处精确对齐。
 * 2. 配合 Control Unit 的统一时序 (t-1 读, t 给 Valid)。
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
    output logic [DATA_WIDTH_ACCUM-1:0] axim_rd_data_out [SYSTOLIC_ARRAY_WIDTH], //vivado报错需要加signed

    // ========================================================================
    // 3. Control Unit 接口 (控制信号)
    // ========================================================================
    
    // --- A-Flow (Input) 控制 ---
    input logic [ADDR_WIDTH-1:0] ctrl_rd_addr_a, 
    input logic                  ctrl_rd_en_a,
    input logic                  ctrl_a_valid,    
    input logic                  ctrl_a_switch,   
    
    // --- B-Flow (Weight) 控制 ---
    input logic [ADDR_WIDTH-1:0] ctrl_rd_addr_b, 
    input logic                  ctrl_rd_en_b,
    input logic                  ctrl_b_accept_w, 
    input logic [$clog2(SYSTOLIC_ARRAY_WIDTH)-1:0] ctrl_b_weight_index, 

    // --- C-Flow (Bias) 控制 ---
    input logic [ADDR_WIDTH-1:0] ctrl_rd_addr_c, 
    input logic                  ctrl_rd_en_c,
    input logic                  ctrl_c_valid,    // [NEW] 新增 C Valid 端口
    input logic [2:0]            ctrl_vpu_mode,

    // --- D-Flow (Result) 控制 ---
    input logic [ADDR_WIDTH-1:0] ctrl_wr_addr_d, 
    
    // --- Systolic 使能掩码 ---
    input logic [SYSTOLIC_ARRAY_WIDTH-1:0] ctrl_row_mask, // 'K' 维度 (i)
    input logic [SYSTOLIC_ARRAY_WIDTH-1:0] ctrl_col_mask, // 'N' 维度 (j)

    // ========================================================================
    // 4. 状态输出 (给 Control Unit)
    // ========================================================================
    output logic core_writeback_valid 
);
    localparam W = SYSTOLIC_ARRAY_WIDTH;

    // --- 内部连线: Buffer 读出 (32-bit) ---
    logic signed [DATA_WIDTH_ACCUM-1:0] ib_rd_a [W];
    logic signed [DATA_WIDTH_ACCUM-1:0] ib_rd_b [W];
    logic signed [DATA_WIDTH_ACCUM-1:0] ib_rd_c [W];

    // --- 内部连线: 截断 (32b -> 8b) ---
    logic signed [DATA_WIDTH_IN-1:0] sys_in_a_raw [W];
    logic signed [DATA_WIDTH_IN-1:0] sys_in_b_raw [W];

    // --- 内部连线: A-Flow Skewed ---
    logic signed [DATA_WIDTH_IN-1:0] sys_in_a_skewed [W];
    logic                            sys_val_a_skewed  [W];
    logic                            sys_sw_a_skewed   [W];

    // --- 内部连线: B-Flow Skewed ---
    logic signed [DATA_WIDTH_IN-1:0] sys_in_b_skewed [W];
    logic        [$clog2(W)-1:0]     sys_idx_b_skewed  [W];
    logic                            sys_acc_b_skewed  [W];

    // --- 内部连线: C-Flow Skewed (Modified) ---
    logic signed [DATA_WIDTH_ACCUM-1:0] sys_in_c_skewed [W];
    logic                               sys_val_c_skewed [W]; // [NEW] 增加 Valid 连线

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
        .host_wr_addr(host_wr_addr_in),
        .host_wr_en(host_wr_en_in),
        .host_wr_data(host_wr_data_in),
        .rd_addr_a(ctrl_rd_addr_a), .rd_en_a(ctrl_rd_en_a), .rd_data_a(ib_rd_a),
        .rd_addr_b(ctrl_rd_addr_b), .rd_en_b(ctrl_rd_en_b), .rd_data_b(ib_rd_b),
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
        .wr_addr(ctrl_wr_addr_d),
        .wr_en(aligned_wr_valid),
        .wr_data(aligned_wr_data),
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
            assign sys_in_a_raw[i_tr] = ib_rd_a[i_tr][DATA_WIDTH_IN-1:0];
            assign sys_in_b_raw[i_tr] = ib_rd_b[i_tr][DATA_WIDTH_IN-1:0];
        end
    endgenerate

    // ========================================================================
    // 逻辑 4: Skew Buffers (关键时序对齐)
    // ========================================================================
    genvar i, j, k;
    generate
        // --- A-Flow Skew (Left Inputs) ---
        // 目标: 第 i 行延迟 i 个周期
        for (i = 0; i < W; i++) begin : a_skew_gen 
            if (i == 0) begin
                assign sys_in_a_skewed[0] = sys_in_a_raw[0];
                assign sys_val_a_skewed[0] = ctrl_a_valid;
                assign sys_sw_a_skewed[0]  = ctrl_a_switch;
            end else begin
                logic signed [DATA_WIDTH_IN-1:0] delay_data [i];
                logic                            delay_val  [i];
                logic                            delay_sw   [i];
                always_ff @(posedge clk) begin
                    if (rst) begin
                        for(int d=0; d<i; d++) begin
                            delay_data[d] <= '0; delay_val[d] <= '0; delay_sw[d] <= '0;
                        end
                    end else begin
                        delay_data[0] <= sys_in_a_raw[i];
                        delay_val[0]  <= ctrl_a_valid;
                        delay_sw[0]   <= ctrl_a_switch;
                        for(int d=1; d<i; d++) begin
                            delay_data[d] <= delay_data[d-1];
                            delay_val[d]  <= delay_val[d-1];
                            delay_sw[d]   <= delay_sw[d-1];
                        end
                    end
                end
                assign sys_in_a_skewed[i] = delay_data[i-1];
                assign sys_val_a_skewed[i] = delay_val[i-1];
                assign sys_sw_a_skewed[i] = delay_sw[i-1];
            end
        end

        // --- B-Flow Skew (Top Inputs) ---
        // 目标: 第 j 列延迟 j 个周期
        for (j = 0; j < W; j++) begin : b_skew_gen 
            if (j == 0) begin
                assign sys_in_b_skewed[0] = sys_in_b_raw[0];
                assign sys_idx_b_skewed[0] = ctrl_b_weight_index;
                assign sys_acc_b_skewed[0] = ctrl_b_accept_w;
            end else begin
                logic signed [DATA_WIDTH_IN-1:0] delay_data [j];
                logic [$clog2(W)-1:0]            delay_idx  [j];
                logic                            delay_acc  [j];
                always_ff @(posedge clk) begin
                    if (rst) begin
                        for(int d=0; d<j; d++) begin
                            delay_data[d] <= '0; delay_idx[d] <= '0; delay_acc[d] <= '0;
                        end
                    end else begin
                        delay_data[0] <= sys_in_b_raw[j];
                        delay_idx[0]  <= ctrl_b_weight_index;
                        delay_acc[0]  <= ctrl_b_accept_w;
                        for(int d=1; d<j; d++) begin
                            delay_data[d] <= delay_data[d-1];
                            delay_idx[d]  <= delay_idx[d-1];
                            delay_acc[d]  <= delay_acc[d-1];
                        end
                    end
                end
                assign sys_in_b_skewed[j] = delay_data[j-1];
                assign sys_idx_b_skewed[j] = delay_idx[j-1];
                assign sys_acc_b_skewed[j] = delay_acc[j-1];
            end
        end
        
        // --- [Modified] C-Flow Skew (Bias Inputs) ---
        // 目标: 第 j 列延迟 j 个周期，并且 Valid 信号同步延迟
        for (k = 0; k < W; k++) begin : c_skew_gen 
            if (k == 0) begin
                // 第0列无延迟 (由CU保证对齐)
                assign sys_in_c_skewed[0] = ib_rd_c[0];
                assign sys_val_c_skewed[0] = ctrl_c_valid; // [NEW]
            end else begin
                logic signed [DATA_WIDTH_ACCUM-1:0] delay_data [k];
                logic                               delay_val  [k]; // [NEW] Valid 延迟链
                always_ff @(posedge clk) begin
                    if (rst) begin
                        for(int d=0; d<k; d++) begin
                            delay_data[d] <= '0;
                            delay_val[d]  <= '0;
                        end
                    end else begin
                        delay_data[0] <= ib_rd_c[k];
                        delay_val[0]  <= ctrl_c_valid;
                        for(int d=1; d<k; d++) begin
                            delay_data[d] <= delay_data[d-1];
                            delay_val[d]  <= delay_val[d-1];
                        end
                    end
                end
                assign sys_in_c_skewed[k] = delay_data[k-1];
                assign sys_val_c_skewed[k] = delay_val[k-1]; // [NEW]
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
        // A-Flow (Input, Left)
        .sys_data_in(sys_in_a_skewed),
        .sys_valid_in(sys_val_a_skewed),
        .sys_switch_in(sys_sw_a_skewed),
        // B-Flow (Weight, Top)
        .sys_weight_in(sys_in_b_skewed),
        .sys_index_in(sys_idx_b_skewed),
        .sys_accept_w_in(sys_acc_b_skewed),
        // Controls
        .sys_enable_rows(ctrl_row_mask),
        .sys_enable_cols(ctrl_col_mask),
        // Output
        .sys_data_out(sys_out_data),
        .sys_valid_out(sys_out_valid)
    );

    // ========================================================================
    // 模块 6: VPU (Vector Processing Unit) - Modified
    // ========================================================================
    vpu #(
        .VPU_WIDTH(W),
        .DATA_WIDTH_IN(DATA_WIDTH_ACCUM)
    ) vpu_inst (
        .clk(clk),
        .rst(rst),
        .vpu_mode(ctrl_vpu_mode),
        // Systolic Result
        .vpu_sys_data_in(sys_out_data),
        .vpu_sys_valid_in(sys_out_valid),
        // Bias Input (Skewed)
        .vpu_bias_data_in(sys_in_c_skewed),
        .vpu_bias_valid_in(sys_val_c_skewed), // [NEW] 连接 Valid 延迟链
        // Output
        .vpu_data_out(vpu_out_data),
        .vpu_valid_out(vpu_out_valid)
    );

    // ========================================================================
    // 逻辑 7: Output De-skew Logic (输出对齐)
    // ========================================================================
    // VPU 每一列的输出时间不同 (第 j 列比第 0 列晚 j 个周期)
    // 目标: 对第 j 列再次延迟 (W-1-j) 个周期，使得所有列在同一时刻对齐，方便打包写入 Buffer
    logic [W-1:0] aligned_valid_pipe;
    genvar i_dsk;
    generate
        for (i_dsk = 0; i_dsk < W; i_dsk++) begin : deskew_gen
            localparam int DELAY = (W - 1) - i_dsk;
            if (DELAY == 0) begin
                // 最后一列 (j=15): 无需等待，直接通过
                assign aligned_wr_data[i_dsk]    = vpu_out_data[i_dsk];
                assign aligned_valid_pipe[i_dsk] = vpu_out_valid[i_dsk];
            end else begin
                logic signed [DATA_WIDTH_ACCUM-1:0] pipe_data [DELAY];
                logic                               pipe_valid [DELAY];
                always_ff @(posedge clk) begin
                    if (rst) begin
                        for(int d=0; d<DELAY; d++) begin
                            pipe_data[d] <= '0;
                            pipe_valid[d] <= '0;
                        end
                    end else begin
                        pipe_data[0]  <= vpu_out_data[i_dsk];
                        pipe_valid[0] <= vpu_out_valid[i_dsk];
                        for(int d=1; d<DELAY; d++) begin
                            pipe_data[d]  <= pipe_data[d-1];
                            pipe_valid[d] <= pipe_valid[d-1];
                        end
                    end
                end
                assign aligned_wr_data[i_dsk]    = pipe_data[DELAY-1];
                assign aligned_valid_pipe[i_dsk] = pipe_valid[DELAY-1];
            end
        end
    endgenerate

    // 最终写使能逻辑: 
    // 只有当被掩码启用(Masked)的所有列都输出 Valid 时，才认为这一行数据准备好了
    logic [W-1:0] masked_valid_pipe;
    genvar i_vld;
    generate
        for (i_vld = 0; i_vld < W; i_vld++) begin
            // 如果 col_mask[i] 是 0 (该列被禁用)，则我们强行认为它 Valid (不在乎它的状态)
            // 如果 col_mask[i] 是 1 (该列启用)，则必须等待 aligned_valid_pipe 为 1
            assign masked_valid_pipe[i_vld] = aligned_valid_pipe[i_vld] | (~ctrl_col_mask[i_vld]);
        end
    endgenerate
    
    assign aligned_wr_valid = &masked_valid_pipe; // AND-Reduction: 所有列就绪
    assign core_writeback_valid = aligned_wr_valid;

endmodule
`timescale 1ns/1ps
`default_nettype none

/**
 * 模块名: top_tpu
 * 功能: TPU 顶层封装 (Top Level Integration)
 * 接口:
 * - APB Slave: 用于寄存器配置 (M, K, N, Base Addrs, Start)
 * - AXI4 Slave (Write): 用于 Host 向 TPU 写入数据 (A, B, C)
 * - AXI4 Master (Write): 用于 TPU 向 DDR 写回结果 (D)
 */
module top_tpu #(
    parameter int AXI_DATA_WIDTH       = 64,   // AXI 总线位宽
    parameter int SYSTOLIC_ARRAY_WIDTH = 16,   // 脉动阵列大小 (16x16)
    parameter int DATA_WIDTH           = 8,    // 输入数据位宽 (int8)
    parameter int ACCUM_WIDTH          = 32,   // 累加数据位宽 (int32)
    parameter int ADDR_WIDTH           = 10    // 内部 SRAM 地址深度 (1024)
)(
    input logic clk,
    input logic rst_n, // Active Low Reset

    // ========================================================================
    // 1. APB 配置接口 (Slave)
    // ========================================================================
    input  logic        psel,
    input  logic        penable,
    input  logic        pwrite,
    input  logic [31:0] paddr,
    input  logic [31:0] pwdata,
    output logic [31:0] prdata,
    output logic        pready,
    output logic        pslverr,

    // ========================================================================
    // 2. AXI4 Slave 接口 (Write Data In)
    // ========================================================================
    // Write Address
    input  logic [31:0]             s_axi_awaddr,
    input  logic [7:0]              s_axi_awlen,
    input  logic [2:0]              s_axi_awsize,
    input  logic [1:0]              s_axi_awburst,
    input  logic                    s_axi_awvalid,
    output logic                    s_axi_awready,
    // Write Data
    input  logic [AXI_DATA_WIDTH-1:0] s_axi_wdata,
    input  logic [AXI_DATA_WIDTH/8-1:0] s_axi_wstrb,
    input  logic                      s_axi_wlast,
    input  logic                      s_axi_wvalid,
    output logic                      s_axi_wready,
    // Write Response
    output logic [1:0]              s_axi_bresp,
    output logic                    s_axi_bvalid,
    input  logic                    s_axi_bready,

    // ========================================================================
    // 3. AXI4 Master 接口 (Write Data Out)
    // ========================================================================
    // Write Address
    output logic [31:0]             m_axi_awaddr,
    output logic [7:0]              m_axi_awlen,
    output logic [2:0]              m_axi_awsize,
    output logic [1:0]              m_axi_awburst,
    output logic                    m_axi_awvalid,
    input  logic                    m_axi_awready,
    // Write Data
    output logic [AXI_DATA_WIDTH-1:0] m_axi_wdata,
    output logic [AXI_DATA_WIDTH/8-1:0] m_axi_wstrb,
    output logic                      m_axi_wlast,
    output logic                      m_axi_wvalid,
    input  logic                      m_axi_wready,
    // Write Response
    input  logic [1:0]              m_axi_bresp,
    input  logic                    m_axi_bvalid,
    output logic                    m_axi_bready
);

    // ========================================================================
    // 内部信号声明
    // ========================================================================
    
    // --- Global Reset ---
    logic internal_rst;
    logic soft_rst;
    // 复位逻辑: 外部硬复位 OR APB软复位 (Active High)
    assign internal_rst = (!rst_n) || soft_rst;

    // --- Config Signals (APB -> Others) ---
    logic        cmd_valid;
    logic [63:0] cmd_data;
    logic        cmd_ready;
    logic        cu_busy;
    
    logic        compute_done_irq;
    logic        dump_done_irq;
    logic        start_dump;
    logic [63:0] reg_ddr_addr;
    
    // 内部解包这些配置信号给 Packer 使用 (因为 APB 模块已经打包好了)
    // cmd_data format: [63:54]D, [53:44]C, [43:34]B, [33:24]A, [23:16]N, [15:8]K, [7:0]M
    // Packer 需要 M, N, D_Addr
    // 注意: Packer 需要的是 "当前的配置"，而 cmd_data 是推入 FIFO 的指令。
    // 这是一个潜在的设计点: Packer 应该从 APB 直接读取 "静态配置" 还是从 CU 获取？
    // 根据 APB 模块设计，它输出了 reg_ddr_addr，但其他的 M/N/Addr_D 是寄存器。
    // 为了简化，我们假设 Packer 直接读取 APB 的寄存器输出 (需要修改 APB 模块暴露这些信号吗？)
    // 让我们回头看 APB 模块: 它目前只暴露了 cmd_data。
    // **修正**: Packer 需要直接访问寄存器值，而不是 FIFO 指令。
    // 但 APB 模块确实没有暴露 r_m_len 等。
    // 解决方案: 我们可以暂时利用 cmd_data (假设 Host 在 start_dump 前配置好了寄存器)
    // 或者修改 APB 模块。
    // 鉴于 cmd_data 包含了所有信息，我们可以直接解包 cmd_data 给 Packer 使用。
    // (前提: Start Dump 时，寄存器里的值就是 Packer 需要的值)
    
    wire [31:0] cfg_m_len  = {24'b0, cmd_data[7:0]};
    wire [31:0] cfg_n_len  = {24'b0, cmd_data[23:16]};
    wire [31:0] cfg_addr_d = {22'b0, cmd_data[63:54]};

    // --- Data Path Signals ---
    
    // Unpacker -> Core (Host Write)
    logic [ADDR_WIDTH-1:0]      host_wr_addr;
    logic                       host_wr_en;
    logic [ACCUM_WIDTH-1:0]     host_wr_data [SYSTOLIC_ARRAY_WIDTH];

    // Packer -> Core (Master Read)
    logic [ADDR_WIDTH-1:0]      axim_rd_addr;
    logic                       axim_rd_en;
    logic [ACCUM_WIDTH-1:0]     axim_rd_data [SYSTOLIC_ARRAY_WIDTH]; //vivado报错，需要加signed

    // Control Unit -> Core
    logic [ADDR_WIDTH-1:0] ctrl_rd_addr_a, ctrl_rd_addr_b, ctrl_rd_addr_c, ctrl_wr_addr_d;
    logic                  ctrl_rd_en_a, ctrl_rd_en_b, ctrl_rd_en_c;
    logic                  ctrl_a_valid, ctrl_a_switch;
    logic                  ctrl_b_accept_w;
    logic [$clog2(SYSTOLIC_ARRAY_WIDTH)-1:0] ctrl_b_weight_index;
    logic                  ctrl_c_valid;
    logic                  ctrl_psum_valid; // [新增] 声明连接线
    logic [2:0]            ctrl_vpu_mode;
    logic                  core_writeback_valid;
    logic [SYSTOLIC_ARRAY_WIDTH-1:0] ctrl_row_mask, ctrl_col_mask;

    // ========================================================================
    // 1. APB Config Slave 实例化
    // ========================================================================
    apb_config_slave #(
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_apb (
        .pclk(clk),
        .presetn(rst_n), // APB use active low
        .paddr(paddr),
        .psel(psel),
        .penable(penable),
        .pwrite(pwrite),
        .pwdata(pwdata),
        .prdata(prdata),
        .pready(pready),
        .pslverr(pslverr),

        .cmd_valid(cmd_valid),
        .cmd_data(cmd_data),
        .cmd_ready(cmd_ready),
        .cu_busy(cu_busy),

        .soft_rst(soft_rst),
        .compute_done_irq(compute_done_irq),
        .dump_done_irq(dump_done_irq),

        .start_dump(start_dump),
        .reg_ddr_addr(reg_ddr_addr)
    );

    // ========================================================================
    // 2. AXI Slave Unpacker 实例化
    // ========================================================================
    // 简单的地址解码: 假设 0x0000-0xFFFF 是 Int8 (A/B), 0x10000+ 是 Int32 (C)
    // 这里简化处理: 全部默认为 Int8，或者由额外信号控制。
    // 为了支持 C 矩阵写入，我们可以利用 awaddr 的高位来区分。
    // 假设 Buffer 深度 1024。 Row 0~511 (A/B), Row 512~1023 (C/D).
    // 实际上，C 矩阵是 int32。
    // 让我们加一个简单的逻辑: 如果 Host 写地址 >= 0x8000 (Row 512 * 64B)，则认为是 Int32。
    logic cfg_data_type_is_int32;
    assign cfg_data_type_is_int32 = (s_axi_awaddr[15:0] >= 16'h8000);

    axi_slave_unpacker #(
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .SRAM_DATA_WIDTH(ACCUM_WIDTH),
        .ARRAY_WIDTH(SYSTOLIC_ARRAY_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_unpacker (
        .clk(clk),
        .rst(internal_rst),
        .cfg_data_type_is_int32(cfg_data_type_is_int32),

        .awaddr(s_axi_awaddr), .awlen(s_axi_awlen), .awsize(s_axi_awsize), 
        .awburst(s_axi_awburst), .awvalid(s_axi_awvalid), .awready(s_axi_awready),
        .wdata(s_axi_wdata), .wstrb(s_axi_wstrb), .wlast(s_axi_wlast), 
        .wvalid(s_axi_wvalid), .wready(s_axi_wready),
        .bresp(s_axi_bresp), .bvalid(s_axi_bvalid), .bready(s_axi_bready),

        .host_wr_addr(host_wr_addr),
        .host_wr_en(host_wr_en),
        .host_wr_data(host_wr_data)
    );

    // ========================================================================
    // 3. TPU Core 实例化
    // ========================================================================
    tpu_core #(
        .SYSTOLIC_ARRAY_WIDTH(SYSTOLIC_ARRAY_WIDTH),
        .DATA_WIDTH_IN(DATA_WIDTH),
        .DATA_WIDTH_ACCUM(ACCUM_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_core (
        .clk(clk),
        .rst(internal_rst),

        // Host Write Interface
        .host_wr_addr_in(host_wr_addr),
        .host_wr_en_in(host_wr_en),
        .host_wr_data_in(host_wr_data),

        // AXI Read Interface (From Packer)
        .axim_rd_addr_in(axim_rd_addr),
        .axim_rd_en_in(axim_rd_en),
        .axim_rd_data_out(axim_rd_data),

        // Control Interface
        .ctrl_rd_addr_a(ctrl_rd_addr_a), .ctrl_rd_en_a(ctrl_rd_en_a),
        .ctrl_a_valid(ctrl_a_valid),     .ctrl_a_switch(ctrl_a_switch),
        .ctrl_psum_valid(ctrl_psum_valid), // [新增] 连接输入
        
        .ctrl_rd_addr_b(ctrl_rd_addr_b), .ctrl_rd_en_b(ctrl_rd_en_b),
        .ctrl_b_accept_w(ctrl_b_accept_w), .ctrl_b_weight_index(ctrl_b_weight_index),
        
        .ctrl_rd_addr_c(ctrl_rd_addr_c), .ctrl_rd_en_c(ctrl_rd_en_c),
        .ctrl_c_valid(ctrl_c_valid),     .ctrl_vpu_mode(ctrl_vpu_mode),
        
        .ctrl_wr_addr_d(ctrl_wr_addr_d),
        .ctrl_row_mask(ctrl_row_mask), .ctrl_col_mask(ctrl_col_mask),
        
        .core_writeback_valid(core_writeback_valid)
    );

    // ========================================================================
    // 4. Control Unit 实例化
    // ========================================================================
    control_unit #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .SYSTOLIC_ARRAY_WIDTH(SYSTOLIC_ARRAY_WIDTH)
    ) u_cu (
        .clk(clk),
        .rst(internal_rst),

        .cmd_valid(cmd_valid),
        .cmd_data(cmd_data),
        .cmd_ready(cmd_ready),
        .busy(cu_busy),
        .done_irq(compute_done_irq),

        .ctrl_rd_addr_a(ctrl_rd_addr_a), .ctrl_rd_en_a(ctrl_rd_en_a),
        .ctrl_a_valid(ctrl_a_valid),     .ctrl_a_switch(ctrl_a_switch),
        .ctrl_psum_valid(ctrl_psum_valid), // [新增] 连接输出
        
        .ctrl_rd_addr_b(ctrl_rd_addr_b), .ctrl_rd_en_b(ctrl_rd_en_b),
        .ctrl_b_accept_w(ctrl_b_accept_w), .ctrl_b_weight_index(ctrl_b_weight_index),
        
        .ctrl_rd_addr_c(ctrl_rd_addr_c), .ctrl_rd_en_c(ctrl_rd_en_c),
        .ctrl_c_valid(ctrl_c_valid),     .ctrl_vpu_mode(ctrl_vpu_mode),
        
        .core_writeback_valid(core_writeback_valid),
        .ctrl_wr_addr_d(ctrl_wr_addr_d),
        
        .ctrl_row_mask(ctrl_row_mask),
        .ctrl_col_mask(ctrl_col_mask)
    );

    // ========================================================================
    // 5. AXI Master Packer 实例化
    // ========================================================================
    axi_master_packer #(
        .AXI_DATA_WIDTH(AXI_DATA_WIDTH),
        .SRAM_DATA_WIDTH(ACCUM_WIDTH),
        .ARRAY_WIDTH(SYSTOLIC_ARRAY_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_packer (
        .clk(clk),
        .rst(internal_rst),

        .start_dump(start_dump),
        .dump_done_irq(dump_done_irq),
        
        // 从 cmd_data 解包出来的配置 (或者应该来自寄存器，这里简化复用)
        .reg_ddr_addr(reg_ddr_addr),
        .reg_m_len(cfg_m_len),
        .reg_n_len(cfg_n_len),
        .reg_addr_d(cfg_addr_d),

        // SRAM Interface
        .rd_addr(axim_rd_addr),
        .rd_en(axim_rd_en),
        .rd_data(axim_rd_data),

        // AXI Master Interface
        .awaddr(m_axi_awaddr), .awlen(m_axi_awlen), .awsize(m_axi_awsize),
        .awburst(m_axi_awburst), .awvalid(m_axi_awvalid), .awready(m_axi_awready),
        .wdata(m_axi_wdata), .wstrb(m_axi_wstrb), .wlast(m_axi_wlast),
        .wvalid(m_axi_wvalid), .wready(m_axi_wready),
        .bresp(m_axi_bresp), .bvalid(m_axi_bvalid), .bready(m_axi_bready)
    );

endmodule
`timescale 1ns/1ps
`default_nettype none

/**
 * 模块名: apb_config_slave
 * 功能: TPU 配置接口 (Register File)
 * 协议: APB3 (PCLK, PRESETn, PSEL, PENABLE, PWRITE, PWDATA, PRDATA, PREADY, PSLVERR)
 * 描述:
 * - 管理 TPU 的配置寄存器 (M, K, N, Base Addrs)
 * - 触发 Control Unit 的指令 FIFO
 * - 触发 AXI Master Packer 的搬运任务
 * - 反馈状态 (Busy, Done)
 */
module apb_config_slave #(
    parameter int ADDR_WIDTH = 10  // 内部 SRAM 地址位宽 (1024深度)
)(
    // --- APB Interface ---
    input  logic        pclk,
    input  logic        presetn,
    input  logic [31:0] paddr,
    input  logic        psel,
    input  logic        penable,
    input  logic        pwrite,
    input  logic [31:0] pwdata,
    output logic [31:0] prdata,
    output logic        pready,
    output logic        pslverr,

    // --- To Control Unit (Command FIFO) ---
    output logic        cmd_valid,      // Pulse: Push command to FIFO
    output logic [63:0] cmd_data,       // Packed command payload
    input  logic        cmd_ready,      // From CU: FIFO not full (for status check)
    input  logic        cu_busy,        // From CU: System Busy

    // --- To Control Unit (Global Control) ---
    output logic        soft_rst,       // Global Soft Reset

    // --- Interrupts / Status Signals ---
    input  logic        compute_done_irq, // From CU: One calculation task done
    input  logic        dump_done_irq,    // From Packer: DMA transfer done

    // --- To AXI Master Packer (Data Dump) ---
    output logic        start_dump,     // Pulse: Start DMA transaction
    output logic [63:0] reg_ddr_addr    // DDR Base Address (64-bit)
    // Note: Packer also reads reg_m_len, reg_n_len, reg_addr_d internally from here
    // We will expose them as outputs below
);

    // ========================================================================
    // 1. 寄存器地址定义 (Address Map)
    // ========================================================================
    localparam ADDR_CTRL       = 8'h00;
    localparam ADDR_STATUS     = 8'h04;
    localparam ADDR_M_LEN      = 8'h08;
    localparam ADDR_K_LEN      = 8'h0C;
    localparam ADDR_N_LEN      = 8'h10;
    localparam ADDR_ADDR_A     = 8'h14;
    localparam ADDR_ADDR_B     = 8'h18;
    localparam ADDR_ADDR_C     = 8'h1C;
    localparam ADDR_ADDR_D     = 8'h20;
    localparam ADDR_DDR_L      = 8'h24;
    localparam ADDR_DDR_H      = 8'h28;
    localparam ADDR_CMD_PUSH   = 8'h2C; // Write-Only Trigger

    // ========================================================================
    // 2. 内部寄存器定义
    // ========================================================================
    // Config Registers
    logic [31:0] r_m_len;
    logic [31:0] r_k_len;
    logic [31:0] r_n_len;
    logic [31:0] r_addr_a;
    logic [31:0] r_addr_b;
    logic [31:0] r_addr_c;
    logic [31:0] r_addr_d;
    logic [31:0] r_ddr_l;
    logic [31:0] r_ddr_h;
    
    // Control & Status
    logic        r_soft_rst;
    logic        s_compute_done; // Sticky bit
    logic        s_dump_done;    // Sticky bit

    // ========================================================================
    // 3. APB 写逻辑 (Write Logic)
    // ========================================================================
    
    // APB 握手信号 (Simple, always ready)
    assign pready  = 1'b1;
    assign pslverr = 1'b0;

    // Pulse Generation
    logic push_pulse;
    logic dump_pulse;

    assign cmd_valid  = push_pulse;
    assign start_dump = dump_pulse;
    assign soft_rst   = r_soft_rst;
    assign reg_ddr_addr = {r_ddr_h, r_ddr_l};

    // 寄存器写入与状态更新
    always_ff @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            r_m_len    <= 32'd16;
            r_k_len    <= 32'd16;
            r_n_len    <= 32'd16;
            r_addr_a   <= 32'd0;
            r_addr_b   <= 32'd0;
            r_addr_c   <= 32'd0;
            r_addr_d   <= 32'd0;
            r_ddr_l    <= 32'd0;
            r_ddr_h    <= 32'd0;
            r_soft_rst <= 1'b0;
            
            s_compute_done <= 1'b0;
            s_dump_done    <= 1'b0;
            
            push_pulse <= 1'b0;
            dump_pulse <= 1'b0;
        end else begin
            // 自清零脉冲 (Pulse Auto-Clear)
            push_pulse <= 1'b0;
            dump_pulse <= 1'b0;

            // --- 1. 处理 APB 写操作 ---
            if (psel && penable && pwrite) begin
                case (paddr[7:0]) // 使用低8位解码
                    ADDR_CTRL: begin
                        // Bit 0: CMD_START (Reserved/Direct Trigger?) -> Let's use CMD_PUSH reg
                        // Bit 1: DUMP_START -> Trigger Pulse
                        if (pwdata[1]) dump_pulse <= 1'b1;
                        // Bit 2: SOFT_RST
                        r_soft_rst <= pwdata[2];
                    end
                    // STATUS 是只读/W1C，下面单独处理
                    ADDR_STATUS: begin
                        // Write 1 to Clear (W1C) logic
                        if (pwdata[1]) s_compute_done <= 1'b0;
                        if (pwdata[2]) s_dump_done    <= 1'b0;
                    end
                    ADDR_M_LEN:  r_m_len  <= pwdata;
                    ADDR_K_LEN:  r_k_len  <= pwdata;
                    ADDR_N_LEN:  r_n_len  <= pwdata;
                    ADDR_ADDR_A: r_addr_a <= pwdata;
                    ADDR_ADDR_B: r_addr_b <= pwdata;
                    ADDR_ADDR_C: r_addr_c <= pwdata;
                    ADDR_ADDR_D: r_addr_d <= pwdata;
                    ADDR_DDR_L:  r_ddr_l  <= pwdata;
                    ADDR_DDR_H:  r_ddr_h  <= pwdata;
                    ADDR_CMD_PUSH: begin
                        // 写任意值到此地址都会触发 Push
                        push_pulse <= 1'b1; 
                    end
                    default: ;
                endcase
            end

            // --- 2. 处理硬件中断信号 (Sticky Bits) ---
            // 注意：硬件置位的优先级高于软件清零 (或者视需求而定，这里设为硬件优先)
            if (compute_done_irq) s_compute_done <= 1'b1;
            if (dump_done_irq)    s_dump_done    <= 1'b1;
        end
    end

    // ========================================================================
    // 4. APB 读逻辑 (Read Logic)
    // ========================================================================
    always_comb begin
        prdata = 32'd0;
        if (psel && !pwrite) begin
            case (paddr[7:0])
                ADDR_CTRL:   prdata = {29'd0, r_soft_rst, 2'd0}; // Only RST readable
                ADDR_STATUS: prdata = {29'd0, s_dump_done, s_compute_done, cu_busy}; 
                             // Bit 0: Busy, Bit 1: Compute Done, Bit 2: Dump Done
                ADDR_M_LEN:  prdata = r_m_len;
                ADDR_K_LEN:  prdata = r_k_len;
                ADDR_N_LEN:  prdata = r_n_len;
                ADDR_ADDR_A: prdata = r_addr_a;
                ADDR_ADDR_B: prdata = r_addr_b;
                ADDR_ADDR_C: prdata = r_addr_c;
                ADDR_ADDR_D: prdata = r_addr_d;
                ADDR_DDR_L:  prdata = r_ddr_l;
                ADDR_DDR_H:  prdata = r_ddr_h;
                // PUSH reg returns FIFO status for convenience
                ADDR_CMD_PUSH: prdata = {31'd0, cmd_ready}; 
                default:     prdata = 32'd0;
            endcase
        end
    end

    // ========================================================================
    // 5. 数据打包 (Data Packing for Control Unit)
    // ========================================================================
    // Control Unit 期望的格式:
    // [63:54]D, [53:44]C, [43:34]B, [33:24]A, [23:16]N, [15:8]K, [7:0]M
    
    assign cmd_data = {
        r_addr_d[ADDR_WIDTH-1:0], // [63:54]
        r_addr_c[ADDR_WIDTH-1:0], // [53:44]
        r_addr_b[ADDR_WIDTH-1:0], // [43:34]
        r_addr_a[ADDR_WIDTH-1:0], // [33:24]
        r_n_len[7:0],             // [23:16]
        r_k_len[7:0],             // [15:8]
        r_m_len[7:0]              // [7:0]
    };

endmodule
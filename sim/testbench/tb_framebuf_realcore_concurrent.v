`timescale 1ns/1ps
// Focused real-core stress: continuous display reads and a bounded back-frame
// write stream. This is intentionally smaller than the full BMP regression so
// arbiter cadence and the APUG011 bank state can be inspected quickly.
module tb_framebuf_realcore_concurrent #(
    parameter BUS_TURN_GAP=2,
    parameter WR_GROUP_CYCLES=13,
    parameter GROUPS=2000,
    parameter DATASHEET_TIMING=0
);
    reg clk=0, rst_n=0;
    always #12.5 clk=~clk;
    reg wr_req=0;
    reg [20:0] wr_word_addr=21'd153600;
    reg [31:0] wr_data=32'h12340000;
    reg [3:0] wr_dm=4'h0;
    wire wr_ack;
    reg rd_req=0;
    wire rd_ack, rd_valid, rd_idle, rd_restart_done;
    reg rd_restart=0;
    reg [20:0] rd_base=0;
    wire [31:0] rd_data;
    wire app_wr_en, app_rd_en;
    wire [20:0] app_wr_addr, app_rd_addr;
    wire [31:0] app_wr_din;
    wire [3:0] app_wr_dm;
    wire sdr_rd_en;
    wire [31:0] sdr_rd_dout;
    wire init_done, ref_vld;
    wire mem_clk, cke, cs_n, ras_n, cas_n, we_n;
    wire [1:0] ba;
    wire [10:0] addr;
    wire [3:0] dm;
    wire [31:0] dq;
    wire arb_err;
    integer writes=0, reads=0, groups_written=0, groups_read=0;
    integer pin_writes=0, pin_reads=0, inactive_reads=0;
    integer beat=0, guard=0;

    framebuf_arbiter #(
        .WR_ADDR_FROM_FIFO(1), .BUS_TURN_GAP(BUS_TURN_GAP),
        .WR_GROUP_CYCLES(WR_GROUP_CYCLES), .FRAME_WORDS(18'd153600)
    ) arb (
        .clk(clk), .rst_n(rst_n), .sdr_init_done(init_done), .ref_vld(ref_vld),
        .wr_req(wr_req), .wr_word_addr(wr_word_addr), .wr_data(wr_data), .wr_dm(wr_dm),
        .wr_ack(wr_ack), .rd_req(rd_req), .rd_ack(rd_ack), .rd_data(rd_data),
        .rd_valid(rd_valid), .rd_idle(rd_idle), .rd_restart(rd_restart), .rd_base(rd_base),
        .rd_restart_done(rd_restart_done), .app_wr_en(app_wr_en), .app_wr_addr(app_wr_addr),
        .app_wr_din(app_wr_din), .app_wr_dm(app_wr_dm), .app_rd_en(app_rd_en),
        .app_rd_addr(app_rd_addr), .sdr_rd_en(sdr_rd_en), .sdr_rd_dout(sdr_rd_dout),
        .busy(), .err(arb_err)
    );
    sdram_ctrl_wrap u_sdram (
        .clk(clk), .clk_sft(~clk), .rst_n(rst_n), .init_done(init_done), .ref_vld(ref_vld), .busy(),
        .app_wr_en(app_wr_en), .app_wr_addr(app_wr_addr), .app_wr_din(app_wr_din), .app_wr_dm(app_wr_dm),
        .app_rd_en(app_rd_en), .app_rd_addr(app_rd_addr), .sdr_rd_en(sdr_rd_en), .sdr_rd_dout(sdr_rd_dout),
        .sdram_clk(mem_clk), .sdram_cke(cke), .sdram_cs_n(cs_n), .sdram_ras_n(ras_n),
        .sdram_cas_n(cas_n), .sdram_we_n(we_n), .sdram_ba(ba), .sdram_addr(addr), .sdram_dm(dm), .sdram_dq(dq)
    );
    IS42s32200 #(.mem_sizes(524287),
        .tAC(DATASHEET_TIMING ? 5.5 : 1.0), .tHZ(DATASHEET_TIMING ? 5.5 : 1.0),
        .tOH(DATASHEET_TIMING ? 2.5 : 0.5), .tRAS(DATASHEET_TIMING ? 49.0 : 0.0),
        .tRC(DATASHEET_TIMING ? 70.0 : 0.0), .tRCD(DATASHEET_TIMING ? 21.0 : 0.0),
        .tRP(DATASHEET_TIMING ? 21.0 : 0.0), .tRRD(DATASHEET_TIMING ? 14.0 : 0.0),
        .tDPL(DATASHEET_TIMING ? 14.0 : 0.0)) memory (
        .Dq(dq), .Addr(addr), .Ba(ba), .Clk(mem_clk), .Cke(cke), .Cs_n(cs_n),
        .Ras_n(ras_n), .Cas_n(cas_n), .We_n(we_n), .Dqm(dm)
    );

    always @(posedge clk) begin
        if (rst_n && wr_ack) begin
            writes=writes+1;
            beat=beat+1;
            wr_data <= wr_data + 1;
            if (beat==4) begin
                beat=0; groups_written=groups_written+1;
                wr_word_addr <= wr_word_addr + 21'd4;
                if (groups_written >= GROUPS) wr_req <= 1'b0;
            end
        end
        if (rst_n && rd_ack) groups_read=groups_read+1;
        if (rst_n && rd_valid) reads=reads+1;
    end
    always @(posedge mem_clk) if (rst_n && cke && !cs_n) begin
        if ({ras_n,cas_n,we_n}===3'b100) pin_writes=pin_writes+1;
        if ({ras_n,cas_n,we_n}===3'b101) begin
            pin_reads=pin_reads+1;
            if ((ba==0 && memory.Pc_b0) || (ba==1 && memory.Pc_b1) ||
                (ba==2 && memory.Pc_b2) || (ba==3 && memory.Pc_b3)) inactive_reads=inactive_reads+1;
        end
    end
    initial begin
        repeat(8) @(negedge clk); rst_n=1;
        wait(init_done); repeat(20) @(negedge clk);
        wr_req=1; rd_req=1;
        while ((groups_written < GROUPS || reads < GROUPS*4) && guard < 4000000) begin
            @(negedge clk); guard=guard+1;
        end
        wr_req=0; rd_req=0;
        repeat(100) @(negedge clk);
        $display("CONCURRENT_RESULT gap=%0d wr_gap=%0d groups=%0d cycles=%0d writes=%0d pin_writes=%0d groups_read=%0d reads=%0d pin_reads=%0d inactive_reads=%0d arb_err=%b",
            BUS_TURN_GAP,WR_GROUP_CYCLES,GROUPS,guard,writes,pin_writes,groups_read,reads,pin_reads,inactive_reads,arb_err);
        if (groups_written!=GROUPS || writes!=GROUPS*4 || inactive_reads!=0 || arb_err)
            $fatal(1,"real-core concurrent read/write regression failed");
        $finish;
    end
    initial begin #200000000; $display("CONCURRENT_TIMEOUT"); $finish; end
endmodule

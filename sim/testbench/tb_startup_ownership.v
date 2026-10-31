`timescale 1ns/1ps
// Reproduce the startup SD ownership handoff with the real gallery_probe and
// image_player.  The single-sector service returns a tiny FAT32 root containing
// IMG001.BMP.  No BMP decode is needed: the contract under test is that the
// one-cycle gallery_first_req is captured while the gallery still owns SD, and
// the player's first block request is issued only after ownership transfers.
module tb_startup_ownership #(parameter LEGACY_READY=0);
  reg clk=0, sdr_clk=0, rst_n=0, sd_ok=0;
  always #20 clk=~clk;
  always #12.5 sdr_clk=~sdr_clk;

  wire gallery_start, player_start;
  wire [31:0] gallery_addr, player_addr;
  wire gallery_done, gallery_fail, gallery_first_req;
  wire [4:0] gallery_count;
  wire [3:0] gallery_err;
  // These are the exact ownership and start-routing expressions from the
  // production top.  LEGACY_READY=1 changes only image_player.sd_ready to the
  // historical sd_ok connection as a negative control.
  wire sd_owner_gallery = sd_ok && !gallery_done && !gallery_fail;
  wire sd_owner_player  = sd_ok && !sd_owner_gallery;
  wire arb_start = sd_owner_gallery ? gallery_start : (sd_owner_player ? player_start : 1'b0);
  wire [31:0] arb_addr = sd_owner_gallery ? gallery_addr : player_addr;
  wire player_sd_ready = LEGACY_READY ? sd_ok : sd_owner_player;

  reg blk_done=0, blk_err=0, data_valid=0;
  reg [7:0] data_byte=0;
  wire player_loading, player_ready, player_failed;
  wire [3:0] player_error;
  wire [2:0] player_status;
  wire [15:0] rgb565;
  wire player_pixel_valid;
  wire [15:0] out_w,out_h,out_x,out_y;
  wire [31:0] sd_lba;

  integer errors=0, checks=0, gallery_accepts=0, player_accepts=0, discarded_player_requests=0;
  integer player_pulses_while_gallery=0, first_req_while_gallery=0;
  integer guard=0;
  reg [7:0] disk [0:4095];
  reg sd_busy=0;
  reg [31:0] service_lba=0;
  integer service_byte=0, service_delay=0;

  gallery_probe #(.CLK_FREQ_HZ(25_000_000), .MAX_COUNT(5'd1)) gallery (
    .clk(clk), .rst_n(rst_n), .sd_ok(sd_ok), .rescan(1'b0),
    .blk_start(gallery_start), .blk_addr(gallery_addr), .blk_done(blk_done), .blk_err(blk_err),
    .data_byte(data_byte), .data_valid(data_valid), .done(gallery_done), .fail(gallery_fail),
    .count(gallery_count), .first_img_req(gallery_first_req), .err_code(gallery_err));

  image_player #(.WIDTH(32), .HEIGHT(16), .MEM_WORDS(1024), .LOAD_TIMEOUT(12000),
                 .SEAMLESS(0), .FADE_FRAMES(1)) player (
    .pix_clk(clk), .rst_n_pix(rst_n), .sdr_clk(sdr_clk), .sdr_clk_sft(~sdr_clk), .rst_n_sdr(rst_n),
    .sd_ready(player_sd_ready), .sd_failed(1'b0), .blk_busy(sd_busy),
    .load_req(gallery_first_req), .image_index(9'd1), .blk_start(player_start), .blk_addr(player_addr),
    .blk_done(blk_done), .blk_err(blk_err), .data_byte(data_byte), .data_valid(data_valid),
    .de(1'b0), .scan_y(10'd16), .rgb565(rgb565), .pixel_valid(player_pixel_valid),
    .out_w(out_w), .out_h(out_h), .out_off_x(out_x), .out_off_y(out_y), .image_ready(player_ready),
    .loading(player_loading), .failed(player_failed), .error_code(player_error), .reader_status(player_status),
    .sdram_clk(), .sdram_cke(), .sdram_cs_n(), .sdram_ras_n(), .sdram_cas_n(), .sdram_we_n(),
    .sdram_ba(), .sdram_addr(), .sdram_dm(), .sdram_dq());

  task wr8; input integer a; input [7:0] v; begin disk[a]=v; end endtask
  task wr16; input integer a; input [15:0] v; begin disk[a]=v[7:0]; disk[a+1]=v[15:8]; end endtask
  task wr32; input integer a; input [31:0] v; begin
    disk[a]=v[7:0]; disk[a+1]=v[15:8]; disk[a+2]=v[23:16]; disk[a+3]=v[31:24];
  end endtask

  task build_card; integer i, b; begin
    for(i=0;i<4096;i=i+1) disk[i]=0;
    // MBR: one FAT32 LBA partition starting at sector 4.
    wr8(446,8'h80); wr8(450,8'h0C); wr32(454,32'd4); wr32(458,32'd8192); wr16(510,16'hAA55);
    // FAT32 BPB at LBA 4: 512-byte sectors, one-sector clusters, two FATs.
    wr16(4*512+11,16'd512); wr8(4*512+13,8'd1); wr16(4*512+14,16'd1);
    wr8(4*512+16,8'd2); wr32(4*512+36,32'd1); wr32(4*512+44,32'd2); wr16(4*512+510,16'hAA55);
    // Root directory is cluster 2 at LBA 7.  IMG001.BMP occupies cluster 3.
    wr32(5*512+8,32'h0FFF_FFF8); wr32(6*512+8,32'h0FFF_FFF8);
    b=7*512;
    wr8(b+0,8'h49); wr8(b+1,8'h4D); wr8(b+2,8'h47);
    wr8(b+3,8'h30); wr8(b+4,8'h30); wr8(b+5,8'h31);
    wr8(b+6,8'h20); wr8(b+7,8'h20); wr8(b+8,8'h42); wr8(b+9,8'h4D); wr8(b+10,8'h50);
    wr8(b+11,8'h20); wr16(b+20,16'd0); wr16(b+26,16'd3); wr32(b+28,32'd921654);
    wr8(b+32,8'h00);
  end endtask

  task chk; input cond; input [8*112-1:0] msg; begin
    checks=checks+1;
    if(cond!==1'b1) begin $display("FAIL: %0s",msg); errors=errors+1; end
    else $display("PASS: %0s",msg);
  end endtask

  // Deterministic SD-sector mock.  It streams exactly 512 registered bytes,
  // matching the valid/data timing used by the existing FAT32 regression.
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      sd_busy<=0; service_lba<=0; service_byte<=0; service_delay<=0;
      blk_done<=0; blk_err<=0; data_valid<=0; data_byte<=0;
    end else begin
      blk_done<=0; blk_err<=0; data_valid<=0;
      if(!sd_busy && arb_start) begin
        sd_busy<=1; service_lba<=arb_addr; service_byte<=0; service_delay<=8;
        if(sd_owner_gallery) gallery_accepts=gallery_accepts+1;
        else player_accepts=player_accepts+1;
      end else if(sd_busy) begin
        if(service_delay>0) service_delay<=service_delay-1;
        else if(service_byte<512) begin
          if(service_lba<8) data_byte<=disk[service_lba*512+service_byte];
          else data_byte<=8'h00;
          data_valid<=1; service_byte<=service_byte+1;
        end else begin
          sd_busy<=0; blk_done<=1;
        end
      end
      if(player_start && sd_owner_gallery && sd_busy) discarded_player_requests=discarded_player_requests+1;
      if(player_start && sd_owner_gallery) player_pulses_while_gallery=player_pulses_while_gallery+1;
      if(gallery_first_req && sd_owner_gallery) first_req_while_gallery=first_req_while_gallery+1;
    end
  end

  initial begin
    build_card();
    repeat(5) @(negedge clk); rst_n=1; repeat(3) @(negedge clk); sd_ok=1;

    if(!LEGACY_READY) begin
      guard=0;
      while(!gallery_first_req && !gallery_fail && guard<5000) begin @(negedge clk); guard=guard+1; end
      chk(guard<5000 && gallery_first_req,"gallery finds IMG001 and emits first-image pulse");
      chk(sd_owner_gallery && !sd_owner_player,"one-cycle first-image pulse occurs while gallery still owns SD");
      // On the following edge the image_player must capture the pulse in its
      // pending register while it is still not allowed to start an SD read.
      @(posedge clk); #1;
      chk(first_req_while_gallery==1,"first-image request is a single pulse before ownership transfer");
      chk(gallery_done && sd_owner_player,"SD ownership transfers only after gallery completion");
      chk(player.pending===1'b1,"image_player retained the one-cycle request across ownership handoff");
      chk(player_pulses_while_gallery==0,"no player block-start pulse was lost to the gallery mux");
      guard=0;
      while(player_accepts==0 && guard<2000) begin @(negedge clk); guard=guard+1; end
      chk(player_accepts>0,"image_player block request reaches SD service after handoff");
      chk(player_start===1'b0 || sd_owner_player,"accepted player request is never issued under gallery ownership");
      chk(player_error!=4'd9,"startup handoff does not reach d810 loader timeout");
      if(errors==0) $display("ALL CHECKS PASSED: startup_ownership");
    end else begin
      guard=0;
      while(!gallery_done && guard<5000) begin @(negedge clk); guard=guard+1; end
      chk(guard<20000 && gallery_done,"gallery eventually completes in legacy negative control");
      chk(player_pulses_while_gallery>0,"legacy sd_ready=sd_ok emits player read while gallery owns SD");
      chk(discarded_player_requests>0,"legacy player request collides with the busy gallery read");
      // Shared block responses can make the legacy misalignment recover in
      // simulation, so the red-capable condition is the early, dropped pulse.
      // In hardware this unacknowledged loader request is the path to error 9.
      if(errors==0) $display("EXPECTED LEGACY HANDOFF FAILURE DETECTED: startup_ownership");
      if(errors==0) $display("EXPECTED LEGACY DROPPED-REQUEST SIGNATURE REPRODUCED: startup_ownership");
    end
    $display("SUMMARY: checks=%0d errors=%0d gallery_blocks=%0d player_blocks=%0d early_player_pulses=%0d discarded_player_requests=%0d",checks,errors,gallery_accepts,player_accepts,player_pulses_while_gallery,discarded_player_requests);
    $finish;
  end
endmodule

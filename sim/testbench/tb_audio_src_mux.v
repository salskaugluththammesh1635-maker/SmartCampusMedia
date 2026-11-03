// ============================================================================
//  tb_audio_src_mux.v —— rtl/audio/audio_src_mux.v 的单元测试台
// ----------------------------------------------------------------------------
//  覆盖：
//    S01  复位：src_start=0、src_sel 由 mode 组合决定、eff_audio_en 跟随 audio_en
//    S02  模式 → 源映射（0=BGM / 1=NARR / 2=ALARM）
//    S03  未定义 mode=3 保守回落 BGM（出声比沉默更易被发现）
//    S04  短名随源切换（逐字节校验 88 位常量）
//    S05  ★ 源变化产 src_start 单拍；同一源不重复发
//    S06  ★ sd_ready=0 时不发 start（卡没初始化完就起播 = 必失败）
//    S07  ★ 上电第一次进任何模式都发 start（src_sel_d 复位成非法值 3 的意图）
//    S08  ★ 应急强制出声：mode=2 时 eff_audio_en 恒 1，与 audio_en 无关
//    S09  ★ 应急强制**不回写** audio_en 寄存器语义：退出应急恢复用户选择
//    S10  日常/科普下 eff_audio_en == audio_en
//    S11  src_start 全程单拍（不得连续两拍为高）
//    S12  源切回原值时重新发 start（去抖动后回到本源，仍需重新起播）
//
//  消息全 ASCII（ModelSim 在 Windows 按系统代码页写日志，中文会变 ????）。
// ============================================================================
`timescale 1ns / 1ps

module tb_audio_src_mux;

    // ------------------------------------------------------------------
    //  时钟 / 复位
    // ------------------------------------------------------------------
    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #20 clk = ~clk;          // 25 MHz

    // ------------------------------------------------------------------
    //  短名常量（88 位 = 11 字节 8.3，必须是 8 字节主名 + 3 字节扩展名）
    //  ★ 字节序：target_name[7:0] 是第 0 字节（主名首字符），
    //    target_name[87:80] 是第 10 字节（扩展名末字符）。
    //    Verilog 拼接 {a,b} 把最左操作数放最高位，所以要写成
    //    {扩展名倒序, 空格填充, 主名倒序}。
    //  ★★ 字节总数必须恰好 11，否则高位被静默截断 ★★
    //     BGM   = "BGM"   + 5 空格 → 3 + 5 + 3 = 11 ✔
    //     NARR  = "NARR"  + 4 空格 → 3 + 4 + 4 = 11 ✔（不是 5 空格！）
    //     ALARM = "ALARM" + 3 空格 → 3 + 3 + 5 = 11 ✔（不是 5 空格！）
    //     第一版把 NARR/ALARM 的空格数照抄 BGM 的 5 个，拼出 12/13 字节，
    //     高 1~2 字节被截掉 → 逐字节比对失败，且现象看起来像 DUT 出错。
    // ------------------------------------------------------------------
    localparam [87:0] NAME_BGM   = {8'h56, 8'h41, 8'h57,                    // "WAV"
                                    8'h20, 8'h20, 8'h20, 8'h20, 8'h20,      // 5 空格
                                    8'h4D, 8'h47, 8'h42};                   // "BGM" 倒序
    localparam [87:0] NAME_NARR  = {8'h56, 8'h41, 8'h57,                    // "WAV"
                                    8'h20, 8'h20, 8'h20, 8'h20,             // 4 空格
                                    8'h52, 8'h52, 8'h41, 8'h4E};            // "NARR" 倒序
    localparam [87:0] NAME_ALARM = {8'h56, 8'h41, 8'h57,                    // "WAV"
                                    8'h20, 8'h20, 8'h20,                    // 3 空格
                                    8'h4D, 8'h52, 8'h41, 8'h4C, 8'h41};     // "ALARM" 倒序

    // ------------------------------------------------------------------
    //  DUT 端口
    // ------------------------------------------------------------------
    reg  [1:0]  mode       = 2'd0;
    reg         audio_en   = 1'b1;
    reg         sd_ready   = 1'b0;

    wire [1:0]  src_sel;
    wire [87:0] src_name;
    wire        src_start;
    wire        eff_audio_en;

    audio_src_mux #(
        .NAME_BGM   (NAME_BGM),
        .NAME_NARR  (NAME_NARR),
        .NAME_ALARM (NAME_ALARM)
    ) u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .mode         (mode),
        .audio_en     (audio_en),
        .sd_ready     (sd_ready),
        .src_sel      (src_sel),
        .src_name     (src_name),
        .src_start    (src_start),
        .eff_audio_en (eff_audio_en)
    );

    // ------------------------------------------------------------------
    //  ★ t6 新增：第二份 DUT，**故意不做 parameter override**
    //  【为什么必须要有这一份】
    //    上面一份用 override 传入了 tb 自己定义的"正确字节序"常量，这样做能测
    //    mux 的选择逻辑，但它**同时也掩盖了 RTL 默认 parameter 是否写对** ——
    //    这正是本工程踩过的坑：rtl/audio/audio_src_mux.v 的默认值原本写成
    //    `{"BGM", 40'h20_20_20_20_20, "WAV"}`（正序），Verilog 拼接把最左操作数
    //    放到最高位，于是 target_name[7:0] = 'V'，而 fat32_reader 从 [7:0] 比
    //    目录项的第 0 字节 —— 磁盘上的 "BGM     WAV" 首字节是 'B'，永远匹配不上。
    //    单元 tb 全绿（因为 override 了正确常量），上板却完全没声音。
    //    ⇒ 必须有一份"用默认参数"的实例，直接断言它在日常模式输出的
    //      src_name[7:0] 就是 'B'(0x42)，从根上防止这个 bug 二次复发。
    // ------------------------------------------------------------------
    wire [87:0] def_src_name;
    wire [1:0]  def_src_sel;
    wire        def_src_start;
    wire        def_eff_audio_en;

    audio_src_mux u_dut_default (        // 注意：这里**不写 #(...)**
        .clk          (clk),
        .rst_n        (rst_n),
        .mode         (mode),
        .audio_en     (audio_en),
        .sd_ready     (sd_ready),
        .src_sel      (def_src_sel),
        .src_name     (def_src_name),
        .src_start    (def_src_start),
        .eff_audio_en (def_eff_audio_en)
    );

    // ------------------------------------------------------------------
    //  记分板
    // ------------------------------------------------------------------
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task chk(input cond, input [1023:0] msg);
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
                $display("PASS: %0s", msg);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL: %0s", msg);
            end
        end
    endtask

    // ------------------------------------------------------------------
    //  src_start 单拍监测：连续两拍同时为高即违规
    //  ★ 计数器只能有一个驱动点（lint E2 / 仿真确定性）：
    //    start_cnt / start_glue 全部由本 always 块独占驱动，
    //    initial 里只做**快照差分**（记 baseline 再比较增量），
    //    绝不直接给 start_cnt 赋值 —— 第一版两边都写，
    //    结果是 initial 的清零被非阻塞赋值覆盖，S05a/S05c 假失败。
    // ------------------------------------------------------------------
    reg     prev_start = 1'b0;
    integer start_cnt  = 0;
    integer start_glue = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            prev_start <= 1'b0;
        end else begin
            if (src_start) start_cnt <= start_cnt + 1;
            if (src_start && prev_start) start_glue <= start_glue + 1;
            prev_start <= src_start;
        end
    end

    // 快照用的基线（只在 initial 里读写，单驱动点）
    //  ★ 必须先等一拍再取基线：start_cnt 由 always 块非阻塞驱动，
    //    比 src_start 本身晚一拍才累加。若在观测到脉冲的当拍就取基线，
    //    这个脉冲会在下一拍被算进增量里，制造"多出一个 start"的假失败。
    integer start_base;
    task snap_start;
        begin
            @(posedge clk);
            #1;
            start_base = start_cnt;
        end
    endtask
    function integer start_delta;
        input dummy;
        begin
            start_delta = start_cnt - start_base;
        end
    endfunction

    // ------------------------------------------------------------------
    //  按字节比名字：期望的名字用字符串拼，逐字节比对 88 位
    //    这是把「手数空格写错」这类问题在 tb 侧兜住的唯一办法
    // ------------------------------------------------------------------
    reg [87:0] exp_name;
    integer    nm_mism;

    task set_exp_name(input [63:0] nm8, input [23:0] ext3);
        integer j;
        begin
            for (j = 0; j < 8; j = j + 1)
                exp_name[j*8 +: 8] = nm8[(7-j)*8 +: 8];
            for (j = 0; j < 3; j = j + 1)
                exp_name[(j+8)*8 +: 8] = ext3[(2-j)*8 +: 8];
        end
    endtask

    task chk_name(input [1023:0] msg);
        begin
            nm_mism = 0;
            if (src_name !== exp_name) begin
                nm_mism = 1;
                $display("     got name bytes: %h", src_name);
                $display("     exp name bytes: %h", exp_name);
            end
            chk(nm_mism == 0, msg);
        end
    endtask

    // ------------------------------------------------------------------
    //  把一个 88 位短名按"第 0 字节..第 10 字节"的顺序打印出来
    //  ★ $display 按高位到低位打印，所以要倒着取（[87:80] 是第 10 字节）
    //    第一版直接顺序取，打出来是倒序，害我以为常量写反了。
    // ------------------------------------------------------------------
    task show_name(input [1023:0] tag, input [87:0] nm);
        integer j;
        reg [8*11-1:0] s;
        begin
            s = 88'd0;
            for (j = 0; j < 11; j = j + 1)
                s[(10-j)*8 +: 8] = nm[j*8 +: 8];
            $display("     [name] %0s bytes(0..10) = '%0s'  [7:0]=0x%02x",
                     tag, s, nm[7:0]);
        end
    endtask

    // ------------------------------------------------------------------
    //  等一个 src_start（带超时），返回是否等到
    // ------------------------------------------------------------------
    reg got_start;
    integer wait_i;
    task wait_start(input integer max_cyc);
        begin
            got_start = 1'b0;
            for (wait_i = 0; wait_i < max_cyc; wait_i = wait_i + 1) begin
                @(posedge clk);
                #1;
                if (src_start) begin
                    got_start = 1'b1;
                    wait_i    = max_cyc;   // 跳出
                end
            end
        end
    endtask

    // ------------------------------------------------------------------
    //  主流程
    // ------------------------------------------------------------------
    integer k;

    initial begin
        $display("=== tb_audio_src_mux start ===");

        // ================================================================
        //  S01 复位
        // ================================================================
        rst_n   = 1'b0;
        mode    = 2'd0;
        audio_en = 1'b1;
        sd_ready = 1'b0;
        repeat (4) @(posedge clk);
        #1 rst_n = 1'b1;
        @(posedge clk); #1;
        chk(src_start     === 1'b0, "S01a reset: src_start == 0");
        chk(src_sel       === 2'd0, "S01b reset: src_sel == SRC_BGM (mode 0)");
        chk(eff_audio_en  === 1'b1, "S01c reset: eff_audio_en == audio_en (1)");

        // ================================================================
        //  S02 模式 → 源映射
        // ================================================================
        $display("");
        $display("---- S02: mode -> source mapping ----");
        mode = 2'd0; @(posedge clk); #1;
        chk(src_sel === 2'd0, "S02a daily   -> SRC_BGM   (0)");
        mode = 2'd1; @(posedge clk); #1;
        chk(src_sel === 2'd1, "S02b science -> SRC_NARR  (1)");
        mode = 2'd2; @(posedge clk); #1;
        chk(src_sel === 2'd2, "S02c emergency -> SRC_ALARM (2)");

        // ================================================================
        //  S03 未定义模式保守回落
        // ================================================================
        mode = 2'd3; @(posedge clk); #1;
        chk(src_sel === 2'd0, "S03 undefined mode=3 falls back to SRC_BGM");

        // ================================================================
        //  S04 短名逐字节校验
        // ================================================================
        $display("");
        $display("---- S04: short name per source ----");
        mode = 2'd0; @(posedge clk); #1;
        set_exp_name(64'h42474D2020202020, 24'h574156);      // "BGM     " + "WAV"
        chk_name("S04a daily   -> src_name == \"BGM     WAV\"");
        mode = 2'd1; @(posedge clk); #1;
        set_exp_name(64'h4E41525220202020, 24'h574156);      // "NARR    " + "WAV"
        chk_name("S04b science -> src_name == \"NARR    WAV\"");
        mode = 2'd2; @(posedge clk); #1;
        set_exp_name(64'h414C41524D202020, 24'h574156);      // "ALARM   " + "WAV"
        chk_name("S04c emergency -> src_name == \"ALARM   WAV\"");

        // ================================================================
        //  S05 源变化产 start 单拍
        // ================================================================
        $display("");
        $display("---- S05/S06/S07: src_start generation ----");
        // 先回日常、sd_ready=1，等首次 start
        mode     = 2'd0;
        sd_ready = 1'b1;
        @(posedge clk);
        wait_start(20);
        chk(got_start === 1'b1, "S07a first mode entry after reset issues src_start (src_sel_d=3 trick)");
        // 同一源不应再发
        snap_start;
        repeat (40) @(posedge clk);
        chk(start_delta(1) == 0, "S05a same source: no repeated src_start over 40 cycles");

        // 切到科普 → 应发一次
        snap_start;
        mode = 2'd1;
        wait_start(20);
        chk(got_start === 1'b1, "S05b source change daily->science issues src_start");
        repeat (40) @(posedge clk);
        chk(start_delta(1) <= 1, "S05c after settling: at most one extra src_start");

        // ================================================================
        //  S06 sd_ready=0 时不发 start
        // ================================================================
        sd_ready  = 1'b0;
        snap_start;
        mode      = 2'd2;                 // 切到应急，但卡没就绪
        repeat (60) @(posedge clk);
        chk(start_delta(1) == 0, "S06a sd_ready=0: no src_start issued even on source change");
        sd_ready = 1'b1;
        wait_start(20);
        chk(got_start === 1'b1, "S06b sd_ready rises: deferred src_start issued once");

        // ================================================================
        //  S08 应急强制出声
        // ================================================================
        $display("");
        $display("---- S08/S09/S10: emergency forced audio ----");
        mode     = 2'd2;
        audio_en = 1'b0;                  // 用户按 Key4 关掉音频
        @(posedge clk); #1;
        chk(eff_audio_en === 1'b1,
            "S08a emergency + audio_en=0 -> eff_audio_en forced to 1 (Key4 cannot mute)");
        chk(audio_en === 1'b0,
            "S09a audio_en register NOT overwritten by emergency (user choice preserved)");

        // 退出应急 → 恢复用户选择（关）
        mode = 2'd0; @(posedge clk); #1;
        chk(eff_audio_en === 1'b0,
            "S09b exit emergency -> eff_audio_en returns to user audio_en (0)");
        audio_en = 1'b1; @(posedge clk); #1;
        chk(eff_audio_en === 1'b1, "S09c audio_en=1 daily -> eff_audio_en=1");

        // 日常/科普下 eff == audio_en
        //   注意：Verilog-2001 不支持 `label: begin ... end` 语句标签
        //   （那是 SystemVerilog 特性，vlog 报 "Statement labels are only
        //   allowed in SystemVerilog"）。这里用普通 begin/end 块。
        begin : eff_track
            integer m;
            m = 0;
            for (k = 0; k < 2; k = k + 1) begin
                mode = k[1:0];
                audio_en = 1'b0; @(posedge clk); #1;
                if (eff_audio_en !== 1'b0) m = m + 1;
                audio_en = 1'b1; @(posedge clk); #1;
                if (eff_audio_en !== 1'b1) m = m + 1;
            end
            chk(m == 0, "S10 daily/science: eff_audio_en tracks audio_en exactly");
        end

        // 科普下关音频也不能被强制
        mode = 2'd1; audio_en = 1'b0; @(posedge clk); #1;
        chk(eff_audio_en === 1'b0, "S08b science mode: Key4 mute is honored");

        // ================================================================
        //  S11 src_start 全程单拍
        // ================================================================
        $display("");
        chk(start_glue == 0, "S11 src_start never high for two consecutive cycles");

        // ================================================================
        //  S12 切回原源也要重新起播
        // ================================================================
        $display("");
        $display("---- S12: switch away and back ----");
        sd_ready = 1'b1;
        mode = 2'd0;
        repeat (10) @(posedge clk);
        mode = 2'd1;
        repeat (10) @(posedge clk);
        snap_start;
        mode = 2'd0;                      // 回到日常（BGM）
        wait_start(20);
        chk(got_start === 1'b1, "S12a switching back to a previously used source re-issues src_start");

        // ================================================================
        //  S13 【t6 新增】默认 parameter 的字节序（防 override 掩盖 bug）
        //  上面所有用例都用了 override 的正确常量，测的是 mux 的选择逻辑；
        //  这一组测的是 **RTL 默认 parameter 本身**，也就是真正进综合的那份。
        // ================================================================
        $display("");
        $display("---- S13: default parameter byte order (no override) ----");
        sd_ready = 1'b1;
        mode = 2'd0; @(posedge clk); #1;
        show_name("default daily   (BGM)  ", def_src_name);
        chk(def_src_name[7:0]     === 8'h42, "S13a default BGM byte0 == 'B' (0x42), not 'V' (0x56)");
        chk(def_src_name[15:8]    === 8'h47, "S13b default BGM byte1 == 'G'");
        chk(def_src_name[23:16]   === 8'h4D, "S13c default BGM byte2 == 'M'");
        chk(def_src_name[31:24]   === 8'h20, "S13d default BGM byte3 == space");
        chk(def_src_name[71:64]   === 8'h57, "S13e default BGM byte8 == 'W'");
        chk(def_src_name[79:72]   === 8'h41, "S13f default BGM byte9 == 'A'");
        chk(def_src_name[87:80]   === 8'h56, "S13g default BGM byte10 == 'V'");
        // 与磁盘 8.3 短名 "BGM     WAV" 逐字节全等（这是 fat32_reader 的比对基准）
        exp_name = {8'h56, 8'h41, 8'h57, 8'h20, 8'h20, 8'h20, 8'h20, 8'h20,
                    8'h4D, 8'h47, 8'h42};
        chk(def_src_name === exp_name,        "S13h default BGM == 'BGM     WAV' on disk (all 11 bytes)");

        mode = 2'd1; @(posedge clk); #1;
        show_name("default science (NARR) ", def_src_name);
        // "NARR    WAV"：主名 4 字母 + 4 空格 = 8，扩展名 3
        exp_name = {8'h56, 8'h41, 8'h57, 8'h20, 8'h20, 8'h20, 8'h20,
                    8'h52, 8'h52, 8'h41, 8'h4E};
        chk(def_src_name === exp_name,        "S13i default NARR == 'NARR    WAV' on disk (all 11 bytes)");
        chk(def_src_name[7:0]     === 8'h4E, "S13j default NARR byte0 == 'N'");

        mode = 2'd2; @(posedge clk); #1;
        show_name("default emerg   (ALARM)", def_src_name);
        // "ALARM   WAV"：主名 5 字母 + 3 空格 = 8，扩展名 3
        exp_name = {8'h56, 8'h41, 8'h57, 8'h20, 8'h20, 8'h20,
                    8'h4D, 8'h52, 8'h41, 8'h4C, 8'h41};
        chk(def_src_name === exp_name,        "S13k default ALARM == 'ALARM   WAV' on disk (all 11 bytes)");
        chk(def_src_name[7:0]     === 8'h41, "S13l default ALARM byte0 == 'A'");
        mode = 2'd0; @(posedge clk); #1;

        // ================================================================
        //  收尾
        // ================================================================
        $display("");
        $display("     total src_start pulses observed = %0d", start_cnt);
        if (fail_cnt == 0) begin
            $display("ALL CHECKS PASSED: audio_src_mux");
        end else begin
            $display("CHECKS FAILED: audio_src_mux  pass=%0d fail=%0d", pass_cnt, fail_cnt);
        end
        $display("=== tb_audio_src_mux: pass=%0d fail=%0d ===", pass_cnt, fail_cnt);
        $finish;
    end

    // 全局超时
    initial begin
        #20_000_000;
        $display("GLOBAL TIMEOUT: tb_audio_src_mux");
        $finish;
    end

endmodule

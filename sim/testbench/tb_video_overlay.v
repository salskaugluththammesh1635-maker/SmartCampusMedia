// ============================================================================
// tb_video_overlay —— video_overlay（像素后处理与 OSD 叠加）独立仿真
// ============================================================================
// 被测: rtl/video/video_overlay.v（主体组合；波形历史在 audio_waveform 子模块）
// 目的: OSD 是"看得见的东西"，上板只能靠眼睛判断对错；把每一处像素颜色
//       变成可重跑的断言，才能在改动 KEY7/8/11/12/13 之后确认画面没走样。
//
// 验证项（10 个用例 / 52 条断言）:
//   V01 de=0 消隐:      任何坐标/任何开关下输出恒为 0
//   V02 直通一致性:     全默认档时输出 == 输入（改造前后逐像素一致）
//   V03 KEY7 亮度五档:  100 / 87.5 / 75 / 62.5 / 50% 的精确像素值
//   V04 KEY8 反色:      三通道按位取反，且只作用于图像层
//   V05 KEY11 九宫格:   4 条线的位置命中、相邻像素不命中
//   V06 KEY13 电平条:   幅度正负对称（取绝对值）、高度映射正确
//   V07 KEY12 底条:     y>=464 整行为底条色，y<464 不受影响
//   V08 KEY12 方块:     12 个格位的位序与格内 6 实 2 空
//   V09 图层优先级:     线 > 方块 > 电平条 > 底条 > 图像
//   V10 OSD 免疫前两级: 反色/调暗开着时 OSD 颜色不变
//
// 用法（工作目录 sim/msim_work）:
//   vlog -quiet ../../rtl/video/video_overlay.v ../testbench/tb_video_overlay.v
//   vsim -c -quiet -lib work -do "run -all; quit -f" tb_video_overlay
// ============================================================================
`timescale 1ns/1ps

module tb_video_overlay;

    // ---- 时钟: 25MHz（模块本身是纯组合，此处仅为端口一致性与波形可读）----
    localparam CLK_PERIOD = 40;             // ns
    reg clk;
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg rst_n;

    // ---- 输入 ----
    reg        de          = 1'b1;
    reg [10:0] active_x    = 11'd0;
    reg [9:0]  active_y    = 10'd0;
    reg [23:0] rgb_in      = 24'h00_00_00;
    reg [2:0]  bright_sel  = 3'd0;
    reg        invert_en   = 1'b0;
    reg        grid_en     = 1'b0;
    reg        info_en     = 1'b0;
    reg        level_en    = 1'b0;
    reg [4:0]  info_index  = 5'd0;
    reg [1:0]  info_mode   = 2'd0;
    reg [1:0]  info_auto   = 2'd0;
    reg signed [23:0] audio_sample = 24'sd0;
    reg        audio_valid = 1'b0;
    reg        wave_en     = 1'b0;

    // ---- B1 字幕层 ----
    reg        caption_en  = 1'b0;
    reg [2:0]  play_state  = 3'd0;
    reg        auto_play   = 1'b0;

    // ---- 输出 ----
    wire [23:0] rgb_out;

    video_overlay dut (
        .pixel_clk    (clk),
        .rst_n        (rst_n),
        .de           (de),
        .active_x     (active_x),
        .active_y     (active_y),
        .rgb_in       (rgb_in),
        .bright_sel   (bright_sel),
        .invert_en    (invert_en),
        .grid_en      (grid_en),
        .info_en      (info_en),
        .level_en     (level_en),
        .info_index   (info_index),
        .info_mode    (info_mode),
        .info_auto    (info_auto),
        .audio_sample (audio_sample),
        .audio_valid  (audio_valid),
        .wave_en      (wave_en),
        .caption_en   (caption_en),
        .play_state   (play_state),
        .auto_play    (auto_play),
        .rgb_out      (rgb_out)
    );

    // ========================================================================
    // 检查工具
    // ========================================================================
    integer errors = 0;
    integer checks = 0;
    integer w;                      // 波形历史填充计数
    integer n_hit, n_a, n_b;        // 字幕带像素计数（V13）
    integer n_play, n_emerg, n_pause, n_auto;

    task chk;
        input         cond;
        input [511:0] name;
        begin
            checks = checks + 1;
            if (cond) $display("PASS: %0s", name);
            else begin
                $display("FAIL: %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    task chk_eq24;
        input [23:0]  got;
        input [23:0]  exp;
        input [511:0] name;
        begin
            checks = checks + 1;
            if (got === exp) $display("PASS: %0s", name);
            else begin
                $display("FAIL: %0s (got %06h, expect %06h)", name, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    // 把全部控制量复位成"什么都不开"的默认态（= 改造前的画面）
    task defaults;
        begin
            de         = 1'b1;
            bright_sel = 3'd0;
            invert_en  = 1'b0;
            grid_en    = 1'b0;
            info_en    = 1'b0;
            level_en   = 1'b0;
            info_index = 5'd0;
            info_mode  = 2'd0;
            info_auto  = 2'd0;
            audio_sample = 24'sd0;
            audio_valid  = 1'b0;
            wave_en      = 1'b0;
            caption_en   = 1'b0;
            play_state   = 3'd0;
            auto_play    = 1'b0;
        end
    endtask

    // 组合逻辑: 赋值后等 1ns 再采样（同一次仿真内 #1 足够，不需要时钟）
    task settle;
        begin
            #1;
        end
    endtask

    // 便于阅读的取样函数式写法: 设定一个像素坐标
    task at;
        input [10:0] x_i;
        input [9:0]  y_i;
        begin
            active_x = x_i;
            active_y = y_i;
            #1;
        end
    endtask

    // 推入一个 48 kHz 音频样本：audio_valid 保持 1 拍，等待波形历史移位
    task push_sample;
        input signed [23:0] s;
        begin
            @(negedge clk);
            audio_valid  = 1'b1;
            audio_sample = s;
            @(negedge clk);
            audio_valid  = 1'b0;
        end
    endtask

    // 统计矩形窗口内等于 expect 的像素个数
    //   用途：字幕是"一组点阵笔画"，逐点断言既冗长又脆弱（字形一改就全废），
    //   所以这里只统计"这个窗口里有没有足够多的目标色"——笔画在不在、
    //   衬底在不在、两幅画面是否不同，都能用计数稳定判定。
    task count_rect;
        // 形参顺序按"先 x 后 y、先小后大"：(x0, y0, x1, y1)
        input  [10:0] x0;
        input  [9:0]  y0;
        input  [10:0] x1;
        input  [9:0]  y1;
        input  [23:0] expect;
        output integer n;
        integer xx, yy;
        begin
            n = 0;
            for (yy = y0; yy <= y1; yy = yy + 1) begin
                for (xx = x0; xx <= x1; xx = xx + 1) begin
                    // 注意: 直接传 integer，由 11 位端口自动截断。
                    //   写成 xx[10:0]（对 integer 取位选）在 ModelSim 里不可靠，
                    //   实测会退化成常量 0，导致整个窗口只采样到 (0,0) 一个点。
                    at(xx, yy);
                    if (rgb_out === expect) n = n + 1;
                end
            end
        end
    endtask

    // ========================================================================
    // 主测试序列
    // ========================================================================
    initial begin
        $display("=== tb_video_overlay start ===");

        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // ---------------- V01 de=0 消隐期恒为 0 ----------------
        // 为什么必须验证: 消隐期若漏出像素，屏幕上会看到右边/下边一条彩边。
        //   改造前顶层写的是 `video_rgb = !de ? 0 : ...`，这里把同一约定固化。
        $display("");
        $display("--- V01 de=0 blanking ---");
        defaults;
        rgb_in     = 24'hFF_FF_FF;
        bright_sel = 3'd2;                  // 同时开着亮度，确认仍被压成 0
        grid_en    = 1'b1;                  // 也开着 OSD
        at(11'd213, 10'd160);
        de = 1'b0;
        #1;
        chk_eq24(rgb_out, 24'h00_00_00, "V01 de=0 outputs black even with OSD on");
        at(11'd0, 10'd0);
        chk_eq24(rgb_out, 24'h00_00_00, "V01 de=0 outputs black at origin");
        de = 1'b1;
        #1;

        // ---------------- V02 默认档直通 ----------------
        // 全默认时输出必须与输入**逐像素相同**：这是"新增功能不改变原有观感"
        // 的硬指标，也是本模块唯一允许"什么都不做"的路径。
        $display("");
        $display("--- V02 pass-through at default settings ---");
        defaults;
        rgb_in = 24'h12_34_56;
        at(11'd100, 10'd100);
        chk_eq24(rgb_out, 24'h12_34_56, "V02 default settings pass the pixel through");
        rgb_in = 24'hFF_FF_FF;
        at(11'd639, 10'd479);
        chk_eq24(rgb_out, 24'hFF_FF_FF, "V02 white stays white at the last pixel");
        rgb_in = 24'h00_00_00;
        at(11'd0, 10'd0);
        chk_eq24(rgb_out, 24'h00_00_00, "V02 black stays black at the first pixel");

        // ---------------- V03 KEY7 亮度五档 ----------------
        // 期望值按"右移减法"的定义手算，不用公式在 TB 里重算 ——
        // 若 TB 也用同样的移位表达式，实现写错时两边会一起错，断言就失效了。
        //   255 -> 255 / 224 / 192 / 161 / 127
        //   128 -> 128 / 112 /  96 /  80 /  64
        //    64 ->  64 /  56 /  48 /  40 /  32
        $display("");
        $display("--- V03 KEY7 brightness steps ---");
        defaults;
        rgb_in = {8'hFF, 8'h80, 8'h40};
        at(11'd320, 10'd240);
        bright_sel = 3'd0;
        #1;
        chk_eq24(rgb_out, {8'd255, 8'd128, 8'd64},  "V03 step0 = 100%");
        bright_sel = 3'd1;
        #1;
        chk_eq24(rgb_out, {8'd224, 8'd112, 8'd56},  "V03 step1 = 87.5% (x - x/8)");
        bright_sel = 3'd2;
        #1;
        chk_eq24(rgb_out, {8'd192, 8'd96,  8'd48},  "V03 step2 = 75% (x - x/4)");
        bright_sel = 3'd3;
        #1;
        chk_eq24(rgb_out, {8'd161, 8'd80,  8'd40},  "V03 step3 = 62.5% (x - x/4 - x/8)");
        bright_sel = 3'd4;
        #1;
        chk_eq24(rgb_out, {8'd127, 8'd64,  8'd32},  "V03 step4 = 50% (x >> 1)");

        // ---------------- V04 KEY8 反色 ----------------
        $display("");
        $display("--- V04 KEY8 invert ---");
        defaults;
        rgb_in   = 24'h12_34_56;
        at(11'd320, 10'd240);
        invert_en = 1'b1;
        #1;
        chk_eq24(rgb_out, 24'hED_CB_A9, "V04 invert takes the one's complement");
        rgb_in = 24'hFF_FF_FF;
        #1;
        chk_eq24(rgb_out, 24'h00_00_00, "V04 invert turns white into black");
        invert_en = 1'b0;
        #1;
        chk_eq24(rgb_out, 24'hFF_FF_FF, "V04 invert off restores the pixel");

        // ---------------- V05 KEY11 九宫格 ----------------
        // 线位置: x = 213 / 426，y = 160 / 320。
        // 每条线都要验证"命中"与"相邻像素不命中"，否则无法排除"整行都画"
        // 或"线宽两像素"这类看起来对、实际不对的实现。
        $display("");
        $display("--- V05 KEY11 grid lines ---");
        defaults;
        grid_en = 1'b1;
        rgb_in  = 24'h40_40_40;
        at(11'd213, 10'd100);
        chk_eq24(rgb_out, 24'h00_FF_00, "V05 vertical line hit at x=213");
        at(11'd426, 10'd100);
        chk_eq24(rgb_out, 24'h00_FF_00, "V05 vertical line hit at x=426");
        at(11'd160, 10'd160);
        chk_eq24(rgb_out, 24'h00_FF_00, "V05 horizontal line hit at y=160");
        at(11'd160, 10'd320);
        chk_eq24(rgb_out, 24'h00_FF_00, "V05 horizontal line hit at y=320");
        at(11'd212, 10'd100);
        chk_eq24(rgb_out, 24'h40_40_40, "V05 x=212 is not a line");
        at(11'd214, 10'd100);
        chk_eq24(rgb_out, 24'h40_40_40, "V05 x=214 is not a line");
        at(11'd160, 10'd159);
        chk_eq24(rgb_out, 24'h40_40_40, "V05 y=159 is not a line");
        at(11'd160, 10'd321);
        chk_eq24(rgb_out, 24'h40_40_40, "V05 y=321 is not a line");
        grid_en = 1'b0;
        at(11'd213, 10'd160);
        chk_eq24(rgb_out, 24'h40_40_40, "V05 grid off draws nothing");

        // ---------------- V06 KEY13 音频电平条 ----------------
        // 档位换算: level_h = |sample| 的 bit[20:14]，条顶 = 380 - level_h。
        //   取 524288 = 2^19 → bit20=0、bit19=1 → level_h = 32 → 条顶 = 348。
        //   取满幅 2097151 = 2^21-1 → bit[20:14] 全 1 = 127 → 条顶 = 253。
        $display("");
        $display("--- V06 KEY13 audio level bar ---");
        defaults;
        level_en     = 1'b1;
        rgb_in       = 24'h40_40_40;
        audio_sample = 24'sd524288;
        at(11'd620, 10'd380);
        chk_eq24(rgb_out, 24'h20_FF_20, "V06 bar bottom pixel lit");
        at(11'd620, 10'd348);
        chk_eq24(rgb_out, 24'h20_FF_20, "V06 bar top pixel lit (level_top = 348)");
        at(11'd620, 10'd347);
        chk_eq24(rgb_out, 24'h40_40_40, "V06 one pixel above the bar is empty");
        at(11'd615, 10'd380);
        chk_eq24(rgb_out, 24'h40_40_40, "V06 x=615 is left of the bar");
        at(11'd632, 10'd380);
        chk_eq24(rgb_out, 24'h40_40_40, "V06 x=632 is right of the bar");
        // 负数样本: 取绝对值后必须与正样本完全一样（否则负半周条会消失）
        audio_sample = -24'sd524288;
        at(11'd620, 10'd360);
        chk_eq24(rgb_out, 24'h20_FF_20, "V06 negative sample uses absolute value");
        // 满幅
        audio_sample = 24'sd2097151;
        at(11'd620, 10'd253);
        chk_eq24(rgb_out, 24'h20_FF_20, "V06 full-scale sample reaches level_top = 253");
        at(11'd620, 10'd252);
        chk_eq24(rgb_out, 24'h40_40_40, "V06 full-scale bar stops at 253");
        // 零样本: 只有 y=380 一行亮（level_h = 0）
        audio_sample = 24'sd0;
        at(11'd620, 10'd380);
        chk_eq24(rgb_out, 24'h20_FF_20, "V06 zero sample leaves a single row at 380");
        at(11'd620, 10'd379);
        chk_eq24(rgb_out, 24'h40_40_40, "V06 zero sample draws nothing above 380");
        level_en = 1'b0;
        at(11'd620, 10'd380);
        chk_eq24(rgb_out, 24'h40_40_40, "V06 level off draws nothing");

        // ---------------- V07 KEY12 底部信息条底条 ----------------
        $display("");
        $display("--- V07 KEY12 info bar background ---");
        defaults;
        info_en = 1'b1;
        rgb_in  = 24'h40_40_40;
        at(11'd100, 10'd464);
        chk_eq24(rgb_out, 24'h10_18_20, "V07 y=464 starts the info bar");
        at(11'd100, 10'd479);
        chk_eq24(rgb_out, 24'h10_18_20, "V07 last line is still info bar");
        at(11'd100, 10'd463);
        chk_eq24(rgb_out, 24'h40_40_40, "V07 y=463 is above the info bar");
        at(11'd0, 10'd470);
        chk_eq24(rgb_out, 24'h10_18_20, "V07 bar spans the full first column");
        at(11'd639, 10'd470);
        chk_eq24(rgb_out, 24'h10_18_20, "V07 bar spans the full last column");
        info_en = 1'b0;
        at(11'd100, 10'd470);
        chk_eq24(rgb_out, 24'h40_40_40, "V07 info off draws nothing");

        // ---------------- V08 KEY12 方块位序 ----------------
        // 12 个格位: 0..4=图号, 5..6=模式, 7..9=亮度, 10..11=倍率。
        // 取 index=5'b00001、mode=2'b01、bright=3'd3(011)、auto=2'b10（bit1=1）。
        //   期望点亮: 格0、格5、格7、格8、格11；其余格灭。
        // 格 x 起点 = 8 + idx*8；格内 bd_x[2:0]=0..5 实心、6..7 间隔。
        $display("");
        $display("--- V08 KEY12 bit boxes ---");
        defaults;
        info_en    = 1'b1;
        info_index = 5'b00001;
        info_mode  = 2'b01;
        info_auto  = 2'b10;
        bright_sel = 3'd3;
        at(11'd8, 10'd470);                 // 格0，bd_x=0
        chk_eq24(rgb_out, 24'h40_E0_D0, "V08 box0 lit by info_index[0]");
        at(11'd13, 10'd470);                // 格0，bd_x=5（格内最后一个实心列）
        chk_eq24(rgb_out, 24'h40_E0_D0, "V08 box0 last solid column lit");
        at(11'd14, 10'd470);                // 格0，bd_x=6（格内间隔）
        chk_eq24(rgb_out, 24'h10_18_20, "V08 box0 gap column stays background");
        at(11'd15, 10'd470);                // 格0，bd_x=7（格内间隔）
        chk_eq24(rgb_out, 24'h10_18_20, "V08 box0 second gap column stays background");
        at(11'd16, 10'd470);                // 格1，index[1]=0
        chk_eq24(rgb_out, 24'h10_18_20, "V08 box1 dark because index[1] = 0");
        at(11'd48, 10'd470);                // 格5，mode[0]=1
        chk_eq24(rgb_out, 24'h40_E0_D0, "V08 box5 lit by mode[0]");
        at(11'd56, 10'd470);                // 格6，mode[1]=0
        chk_eq24(rgb_out, 24'h10_18_20, "V08 box6 dark because mode[1] = 0");
        at(11'd64, 10'd470);                // 格7，bright[0]=1
        chk_eq24(rgb_out, 24'h40_E0_D0, "V08 box7 lit by bright_sel[0]");
        at(11'd72, 10'd470);                // 格8，bright[1]=1
        chk_eq24(rgb_out, 24'h40_E0_D0, "V08 box8 lit by bright_sel[1]");
        at(11'd80, 10'd470);                // 格9，bright[2]=0
        chk_eq24(rgb_out, 24'h10_18_20, "V08 box9 dark because bright_sel[2] = 0");
        at(11'd88, 10'd470);                // 格10，auto[0]=0
        chk_eq24(rgb_out, 24'h10_18_20, "V08 box10 dark because auto_sw_sel[0] = 0");
        at(11'd96, 10'd470);                // 格11，auto[1]=1
        chk_eq24(rgb_out, 24'h40_E0_D0, "V08 box11 lit by auto_sw_sel[1]");
        at(11'd104, 10'd470);               // 格12，超出 12 格
        chk_eq24(rgb_out, 24'h10_18_20, "V08 box12 stays background (only 12 boxes)");
        // y 方向边界: 方块只画在 [468,475]，其余行是纯底条
        at(11'd8, 10'd467);
        chk_eq24(rgb_out, 24'h10_18_20, "V08 y=467 above the box row is background");
        at(11'd8, 10'd468);
        chk_eq24(rgb_out, 24'h40_E0_D0, "V08 y=468 starts the box row");
        at(11'd8, 10'd475);
        chk_eq24(rgb_out, 24'h40_E0_D0, "V08 y=475 ends the box row");
        at(11'd8, 10'd476);
        chk_eq24(rgb_out, 24'h10_18_20, "V08 y=476 below the box row is background");

        // ---------------- V09 图层优先级 ----------------
        // 线 > 方块 > 电平条 > 底条 > 图像。
        //   线是校准工具，必须永远可见；方块只在底条区内，与电平条不重叠，
        //   所以"电平条高于底条"这一条要用 y 落在底条区之外的条件验证。
        $display("");
        $display("--- V09 layer priority ---");
        defaults;
        grid_en    = 1'b1;
        info_en    = 1'b1;
        info_index = 5'b11111;
        rgb_in     = 24'h40_40_40;
        at(11'd213, 10'd470);               // 线 + 方块 + 底条 同时命中
        chk_eq24(rgb_out, 24'h00_FF_00, "V09 grid wins over box and info bar");
        info_en = 1'b0;
        grid_en = 1'b0;
        info_en = 1'b1;
        level_en = 1'b1;
        audio_sample = 24'sd2097151;        // 条顶 253，覆盖 y=300
        at(11'd620, 10'd300);               // 电平条命中，但底条区在 464 以下
        chk_eq24(rgb_out, 24'h20_FF_20, "V09 level bar wins over info background");
        // 方块 vs 底条: 方块命中时用方块色，未命中用底条色（V08 已覆盖）
        level_en = 1'b0;
        at(11'd8, 10'd470);
        chk_eq24(rgb_out, 24'h40_E0_D0, "V09 box wins over info background");

        // ---------------- V10 OSD 不受亮度/反色影响 ----------------
        // 这是"做人机界面"的关键: 反色开着时信息条不能变成反色，
        //   否则现场读数全靠猜。验证三个 OSD 元素在极端档位下颜色不变。
        $display("");
        $display("--- V10 OSD immune to brightness and invert ---");
        defaults;
        grid_en    = 1'b1;
        info_en    = 1'b1;
        level_en   = 1'b1;
        info_index = 5'b11111;
        audio_sample = 24'sd2097151;
        bright_sel = 3'd4;                  // 最暗
        invert_en  = 1'b1;                  // 同时反色
        at(11'd213, 10'd100);
        chk_eq24(rgb_out, 24'h00_FF_00, "V10 grid colour unchanged at darkest+invert");
        at(11'd8, 10'd470);
        chk_eq24(rgb_out, 24'h40_E0_D0, "V10 box colour unchanged at darkest+invert");
        at(11'd620, 10'd300);
        chk_eq24(rgb_out, 24'h20_FF_20, "V10 level bar colour unchanged at darkest+invert");
        at(11'd100, 10'd470);
        chk_eq24(rgb_out, 24'h10_18_20, "V10 info background unchanged at darkest+invert");
        // 同一时刻图像层必须**确实**被调暗+反色（确认前两级没被跳过）
        rgb_in = 24'hFF_FF_FF;
        at(11'd320, 10'd240);
        chk_eq24(rgb_out, 24'h80_80_80, "V10 image layer is dimmed then inverted");

        // ---------------- V11 KEY13 音频波形层 ----------------
        // 窗口 x ∈ [64,575]，每 8 像素一个样本，中心线 y=200。
        // 先填 64 个 0，验证安静时是一条 y=200 的直线；再推入 2^21 的正样本，
        // 验证右端最新样本抬高，并与旧样本连线。
        $display("");
        $display("--- V11 KEY13 audio waveform ---");
        defaults;
        wave_en = 1'b1;
        rgb_in  = 24'h40_40_40;
        for (w = 0; w < 64; w = w + 1) push_sample(24'sd0);
        at(11'd320, 10'd200);
        chk_eq24(rgb_out, 24'hFF_FF_40, "V11 silent history draws baseline at y=200");
        at(11'd320, 10'd199);
        chk_eq24(rgb_out, 24'h40_40_40, "V11 one row above baseline is background");
        at(11'd63, 10'd200);
        chk_eq24(rgb_out, 24'h40_40_40, "V11 x=63 is left of the waveform window");
        at(11'd576, 10'd200);
        chk_eq24(rgb_out, 24'h40_40_40, "V11 x=576 is right of the waveform window");

        // 2^21 = 0x20_0000 → sample[23:8] = 0x2000 = 8192 → >>>9 = +16 像素
        push_sample(24'sd2097152);
        at(11'd574, 10'd216);
        chk_eq24(rgb_out, 24'hFF_FF_40, "V11 newest sample raises the right edge");
        at(11'd574, 10'd208);
        chk_eq24(rgb_out, 24'hFF_FF_40, "V11 line connects newest to previous sample");
        at(11'd574, 10'd199);
        chk_eq24(rgb_out, 24'h40_40_40, "V11 left of the line stays background");
        at(11'd320, 10'd200);
        chk_eq24(rgb_out, 24'hFF_FF_40, "V11 older samples remain on the baseline");
        at(11'd320, 10'd216);
        chk_eq24(rgb_out, 24'h40_40_40, "V11 older samples are not raised");

        wave_en = 1'b0;
        at(11'd320, 10'd200);
        chk_eq24(rgb_out, 24'h40_40_40, "V11 wave off draws nothing");

        // 电平条与波形共存：右侧电平条、中间波形，互不覆盖
        level_en     = 1'b1;
        wave_en      = 1'b1;
        audio_sample = 24'sd2097151;
        at(11'd620, 10'd300);
        chk_eq24(rgb_out, 24'h20_FF_20, "V11 level bar still works with waveform on");
        at(11'd320, 10'd200);
        chk_eq24(rgb_out, 24'hFF_FF_40, "V11 waveform still works with level bar on");

        // OSD 不受亮度/反色影响
        bright_sel = 3'd4;
        invert_en  = 1'b1;
        at(11'd320, 10'd200);
        chk_eq24(rgb_out, 24'hFF_FF_40, "V11 waveform colour unchanged at darkest+invert");
        de = 1'b0;
        at(11'd320, 10'd200);
        chk_eq24(rgb_out, 24'd0, "V11 blanking forces waveform output to 0");

        // ---------------- V12 KEY3 科普态常显标记 ----------------
        // 现场反馈"按 KEY3 没有进科普态"，根因是日常与科普两态画面完全相同。
        // 本段锁定科普标记的几何与开关：顶部 y∈[0,7] 通栏 + 左上 x∈[0,23]
        // 且 y∈[8,31] 的块，颜色 24'h00_C8_E0，且只由 info_mode==1 触发。
        $display("");
        $display("--- V12 KEY3 science-mode marker ---");
        defaults;
        rgb_in    = 24'h40_40_40;
        info_mode = 2'b01;

        at(11'd0, 10'd0);
        chk_eq24(rgb_out, 24'h00_C8_E0, "V12 top bar starts at y=0");
        at(11'd639, 10'd7);
        chk_eq24(rgb_out, 24'h00_C8_E0, "V12 top bar spans full width at y=7");
        at(11'd320, 10'd8);
        chk_eq24(rgb_out, 24'h40_40_40, "V12 y=8 leaves the top bar outside the corner block");
        at(11'd0, 10'd8);
        chk_eq24(rgb_out, 24'h00_C8_E0, "V12 corner block starts at x=0,y=8");
        at(11'd23, 10'd31);
        chk_eq24(rgb_out, 24'h00_C8_E0, "V12 corner block ends at x=23,y=31");
        at(11'd24, 10'd20);
        chk_eq24(rgb_out, 24'h40_40_40, "V12 x=24 is right of the corner block");
        at(11'd10, 10'd32);
        chk_eq24(rgb_out, 24'h40_40_40, "V12 y=32 is below the corner block");

        // 日常态（mode=0）与应急态（mode=2）都不画标记
        info_mode = 2'b00;
        at(11'd320, 10'd0);
        chk_eq24(rgb_out, 24'h40_40_40, "V12 normal mode draws no top bar");
        info_mode = 2'b10;
        at(11'd320, 10'd0);
        chk_eq24(rgb_out, 24'h40_40_40, "V12 emergency mode draws no top bar");

        // 标记与既有 OSD 的优先级：九宫格线仍压过标记
        info_mode = 2'b01;
        grid_en   = 1'b1;
        at(11'd213, 10'd160);
        chk_eq24(rgb_out, 24'h00_FF_00, "V12 grid line wins over the science marker");
        grid_en = 1'b0;

        // 标记是设计色，不受亮度/反色影响
        bright_sel = 3'd4;
        invert_en  = 1'b1;
        at(11'd320, 10'd0);
        chk_eq24(rgb_out, 24'h00_C8_E0, "V12 marker colour unchanged at darkest+invert");

        // 消隐期仍然强制为 0（标记不得漏到消隐区）
        de = 1'b0;
        at(11'd320, 10'd0);
        chk_eq24(rgb_out, 24'd0, "V12 blanking forces marker output to 0");
        de = 1'b1;

        // ---------------- V13 B1 字幕层（集成级） ----------------
        //   这里只验证"字幕层接进 overlay 后"的接线与优先级语义：
        //     开关生效 / 衬底压暗 / 笔画色 / 状态行随 play_state 变化 / 带外不受影响。
        //   字形与坐标的逐点正确性由 tb_osd_caption 的 3057 点比对负责，
        //   不在这里重复（否则字形一改就要改两处）。
        $display("");
        $display("--- V13 B1 caption layer ---");
        defaults;
        rgb_in = 24'h40_40_40;

        // 关着的时候：字幕区域必须与"没有字幕层"完全一致
        caption_en = 1'b0;
        at(11'd40, 10'd20);
        chk_eq24(rgb_out, 24'h40_40_40, "V13 caption off leaves title band untouched");
        at(11'd40, 10'd52);
        chk_eq24(rgb_out, 24'h40_40_40, "V13 caption off leaves state band untouched");
        at(11'd40, 10'd450);
        chk_eq24(rgb_out, 24'h40_40_40, "V13 caption off leaves ticker band untouched");

        // 打开后：衬底带把图像压到 1/4 亮度（0x40 -> 0x10）
        caption_en = 1'b1;
        play_state = 3'd4;   // ST_AUTO -> 行 2 "PLAY"
        at(11'd40, 10'd20);
        chk_eq24(rgb_out, 24'h10_10_10, "V13 caption band darkens image to 1/4");

        // 带外必须完全不受影响（画面中心、以及三条带之间的空白）
        at(11'd320, 10'd240);
        chk_eq24(rgb_out, 24'h40_40_40, "V13 image centre outside all caption bands");
        at(11'd320, 10'd40);
        chk_eq24(rgb_out, 24'h40_40_40, "V13 gap between title and state bands");

        // 笔画色：标题带里必须存在近白像素（有字），且不等于衬底色
        count_rect(11'd32, 10'd16, 11'd127, 10'd31, 24'hF0_F0_F0, n_hit);
        chk(n_hit > 40, "V13 title band draws glyph strokes");
        count_rect(11'd32, 10'd16, 11'd127, 10'd31, 24'h10_10_10, n_hit);
        chk(n_hit > 40, "V13 title band shows darkened backdrop behind glyphs");

        // 序号带：info_index 变化必须改变像素（说明 index_val 接到了字幕层）
        count_rect(11'd576, 10'd16, 11'd623, 10'd31, 24'hF0_F0_F0, n_a);
        info_index = 5'd17;
        count_rect(11'd576, 10'd16, 11'd623, 10'd31, 24'hF0_F0_F0, n_b);
        chk(n_a > 0 && n_b > 0, "V13 index band draws glyph strokes");
        chk(n_a != n_b, "V13 index change alters the index glyphs");

        // 状态带：不同 play_state 必须给出不同画面（映射表真的接上了）
        info_index = 5'd0;
        play_state = 3'd4;   // PLAY
        count_rect(11'd32, 10'd48, 11'd103, 10'd63, 24'hF0_F0_F0, n_play);
        play_state = 3'd5;   // EMERGENCY
        count_rect(11'd32, 10'd48, 11'd103, 10'd63, 24'hF0_F0_F0, n_emerg);
        play_state = 3'd3;   // ST_READY
        auto_play  = 1'b0;
        count_rect(11'd32, 10'd48, 11'd103, 10'd63, 24'hF0_F0_F0, n_pause);
        auto_play  = 1'b1;
        count_rect(11'd32, 10'd48, 11'd103, 10'd63, 24'hF0_F0_F0, n_auto);
        chk(n_play > 0 && n_emerg > 0 && n_pause > 0 && n_auto > 0,
            "V13 every play state draws a state word");
        chk(n_emerg > n_play, "V13 EMERGENCY is wider than PLAY");
        chk(n_pause != n_auto, "V13 ST_READY distinguishes PAUSE from AUTO");

        // 标语带：整条 64 字符滚动，必须始终有笔画
        auto_play = 1'b0;
        count_rect(11'd0, 10'd448, 11'd639, 10'd463, 24'hF0_F0_F0, n_hit);
        chk(n_hit > 100, "V13 ticker band draws scrolling text");

        // 字幕层不抢其它 OSD：九宫格线在字幕带之外，仍为纯绿
        grid_en = 1'b1;
        at(11'd213, 10'd160);
        chk_eq24(rgb_out, 24'h00_FF_00, "V13 grid line unaffected by caption layer");
        grid_en = 1'b0;

        // 消隐期强制 0
        de = 1'b0;
        at(11'd40, 10'd20);
        chk_eq24(rgb_out, 24'd0, "V13 blanking forces caption output to 0");
        de = 1'b1;

        // ---------------- 收尾 ----------------
        $display("");
        $display("=== tb_video_overlay: %0d checks, %0d error(s) ===", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: video_overlay");
        else             $display("CHECKS FAILED: %0d error(s)", errors);
        $finish;
    end

endmodule

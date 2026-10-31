// =============================================================================
// tb_img_scaler.v — img_scaler 自适应缩放自检
// =============================================================================
// 【一、两个 DUT 实例，各查各的维度】
//   两个实例吃同一组激励，但每个用例只检查其中一个（CHK_BIG / CHK_SM 门控）。
//
//   DUT_BIG (DST_W=640, DST_H=480) —— 查**真实尺寸下的几何**
//       out_w/out_h/out_off_x/out_off_y/out_pixels、像素总数、坐标不越出窗口、
//       无重复坐标、每一行/每一列都被恰好填满。这些性质全是精确的，与颜色无关。
//
//   DUT_SM  (DST_W=64,  DST_H=48)  —— 查**采样点与行序**
//       源尺寸压到 ≤128×96，源坐标能完整塞进 8 bit，颜色编码 {sx[7:0],sy[7:0]}
//       不会回绕，从而能逐点精确校验采样来源。
//
//   ★ 为什么大实例不能查颜色: 16 bit 颜色装不下 640×480 的坐标（需 20 bit）。
//     若用 {sx[7:0],sy[7:0]} 编码，sx=0 与 sx=256、sy=223 与 sy=479 完全同色，
//     "漏镜像"这类错误会被同色掩盖。
//
// 【二、采样点期望模型（独立于 RTL 的数学表述）】
//   设源长 S、目标长 E。最近邻抽稀且**首像素必被采样**时，第 t 个目标索引
//   对应源索引 floor(t*S/E)。本测试台据此独立算出期望值，不复用 RTL 的相位
//   累加器，因此能抓出 RTL 的编码错误。
//
//   行序（BMP 自底向上）: RTL 先按到达顺序抽稀、再把第 k 个采样行镜像到
//   dst_h-1-k。到达顺序的第 k 个源行是 SH-1-floor(k*S/E)，故目标行 t 的期望源行
//       exp_sy = SH - 1 - floor((EH-1-t) * SH / EH)      （自底向上）
//       exp_sy = floor(t * SH / EH)                       （自顶向下）
//   ★ 两式的差别正好等于整个行序镜像，因此"漏镜像"必然被抓到。
//
// 【三、用例】
//   S01  640×480 → 1:1 居中             S05  320×240 自顶向下
//   S02  320×240 → 1:1 居中 (160,120)   S06  1280×480 自底向上
//   S03  1280×480 → 以宽为准 640×240    T01  128×96 → 64×48（2:1）
//   S04  480×960 → 以高为准 240×480     T02   48×96 → 24×48 (20,0)
//                                       T03   32×24 → 1:1 居中 (16,12)
//                                       T04   96×64 → 64×42（3:2，非整数比）
//                                       T05  128×96 自顶向下
//                                       T06  128×96 自底向上
//                                       T07   45×64 → 32×48（自然宽 33 奇数→强制偶）
// =============================================================================
`timescale 1ns / 1ps

module tb_img_scaler;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #20 clk = ~clk;              // 25MHz

    // ========================================================================
    // 共用激励
    // ========================================================================
    reg         src_start = 1'b0;
    reg  [15:0] src_w = 16'd0;
    reg  [15:0] src_h = 16'd0;
    reg         src_valid = 1'b0;
    reg  [15:0] src_rgb565 = 16'd0;
    reg  [15:0] src_y = 16'd0;

    wire        big_valid;
    wire [15:0] big_rgb, big_x, big_y;
    wire [15:0] big_ow, big_oh, big_ox, big_oy;
    wire        big_ok;
    wire [31:0] big_pix;

    img_scaler #(.DST_W(640), .DST_H(480)) dut_big (
        .clk(clk), .rst_n(rst_n),
        .src_start(src_start), .src_w(src_w), .src_h(src_h),
        .src_valid(src_valid), .src_rgb565(src_rgb565), .src_y(src_y),
        .dst_valid(big_valid), .dst_rgb565(big_rgb), .dst_x(big_x), .dst_y(big_y),
        .out_w(big_ow), .out_h(big_oh), .out_off_x(big_ox), .out_off_y(big_oy),
        .out_cfg_ok(big_ok), .out_pixels(big_pix)
    );

    wire        sm_valid;
    wire [15:0] sm_rgb, sm_x, sm_y;
    wire [15:0] sm_ow, sm_oh, sm_ox, sm_oy;
    wire        sm_ok;
    wire [31:0] sm_pix;

    img_scaler #(.DST_W(64), .DST_H(48)) dut_sm (
        .clk(clk), .rst_n(rst_n),
        .src_start(src_start), .src_w(src_w), .src_h(src_h),
        .src_valid(src_valid), .src_rgb565(src_rgb565), .src_y(src_y),
        .dst_valid(sm_valid), .dst_rgb565(sm_rgb), .dst_x(sm_x), .dst_y(sm_y),
        .out_w(sm_ow), .out_h(sm_oh), .out_off_x(sm_ox), .out_off_y(sm_oy),
        .out_cfg_ok(sm_ok), .out_pixels(sm_pix)
    );

    // ========================================================================
    // 检查框架
    // ========================================================================
    integer checks = 0;
    integer errors = 0;

    task chk;
        input cond;
        input [511:0] msg;
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("FAIL: %0s", msg);
            end
        end
    endtask

    // 源像素内容: (x mod 256, y mod 256)。小容器用例里源坐标恒 < 256，
    // 故该编码就是坐标本身，不会回绕。
    function [15:0] src_color;
        input integer sx;
        input integer sy;
        begin
            src_color = {sx[7:0], sy[7:0]};
        end
    endfunction

    // ---- 用例参数 ----
    integer SW, SH, TD;                 // 源宽高、1=自顶向下
    integer EW, EH, EOX, EOY;           // 期望目标尺寸与偏移
    integer CHK_BIG, CHK_SM;            // 本用例检查哪个实例
    // POS_CHK=1 时才校验采样来源。自然目标长与最终目标长不等（发生钳位或
    // 强制偶数）时，floor(t*S/E) 模型不再适用，此时置 0，只查几何与像素数。
    integer POS_CHK;

    // ---- DUT_BIG 统计（纯几何）----
    integer big_cnt, big_coord_err, big_dup_err, big_print;
    reg     big_seen [0:640*480-1];
    integer big_row_cnt [0:479];
    integer big_col_cnt [0:639];

    always @(posedge clk) begin
        if (rst_n && big_valid && CHK_BIG) begin
            big_cnt = big_cnt + 1;
            if ((big_x < EOX) || (big_x >= EOX + EW) ||
                (big_y < EOY) || (big_y >= EOY + EH)) begin
                big_coord_err = big_coord_err + 1;
                if (big_print < 3) begin
                    $display("  [big] coord out of window (%0d,%0d)", big_x, big_y);
                    big_print = big_print + 1;
                end
            end else begin
                if (big_seen[big_y * 640 + big_x] !== 1'b0) begin
                    big_dup_err = big_dup_err + 1;
                    if (big_print < 3) begin
                        $display("  [big] duplicate (%0d,%0d)", big_x, big_y);
                        big_print = big_print + 1;
                    end
                end
                big_seen[big_y * 640 + big_x] = 1'b1;
                big_row_cnt[big_y] = big_row_cnt[big_y] + 1;
                big_col_cnt[big_x] = big_col_cnt[big_x] + 1;
            end
        end
    end

    // ---- DUT_SM 统计（采样来源精确校验）----
    integer sm_cnt, sm_coord_err, sm_dup_err, sm_pos_err, sm_print;
    reg     sm_seen [0:64*48-1];
    integer got_sx, got_sy, exp_sx, exp_sy, tx, ty;

    always @(posedge clk) begin
        if (rst_n && sm_valid && CHK_SM) begin
            sm_cnt = sm_cnt + 1;
            if ((sm_x < EOX) || (sm_x >= EOX + EW) ||
                (sm_y < EOY) || (sm_y >= EOY + EH)) begin
                sm_coord_err = sm_coord_err + 1;
                if (sm_print < 3) begin
                    $display("  [sm] coord out of window (%0d,%0d)", sm_x, sm_y);
                    sm_print = sm_print + 1;
                end
            end else begin
                if (sm_seen[sm_y * 64 + sm_x] !== 1'b0) begin
                    sm_dup_err = sm_dup_err + 1;
                    if (sm_print < 3) begin
                        $display("  [sm] duplicate (%0d,%0d)", sm_x, sm_y);
                        sm_print = sm_print + 1;
                    end
                end
                sm_seen[sm_y * 64 + sm_x] = 1'b1;

                if (POS_CHK) begin
                    tx = sm_x - EOX;
                    ty = sm_y - EOY;
                    got_sx = sm_rgb[15:8];
                    got_sy = sm_rgb[7:0];
                    // 列: 第 tx 个目标列取源列 floor(tx*SW/EW)
                    exp_sx = (tx * SW) / EW;
                    // 行: 自顶向下直接用 floor；自底向上按到达顺序镜像
                    if (TD) exp_sy = (ty * SH) / EH;
                    else    exp_sy = SH - 1 - (((EH - 1 - ty) * SH) / EH);
                    if (got_sx !== exp_sx) begin
                        sm_pos_err = sm_pos_err + 1;
                        if (sm_print < 3) begin
                            $display("  [sm] col src (%0d,%0d): got %0d want %0d",
                                     sm_x, sm_y, got_sx, exp_sx);
                            sm_print = sm_print + 1;
                        end
                    end
                    if (got_sy !== exp_sy) begin
                        sm_pos_err = sm_pos_err + 1;
                        if (sm_print < 3) begin
                            $display("  [sm] row src (%0d,%0d): got %0d want %0d",
                                     sm_x, sm_y, got_sy, exp_sy);
                            sm_print = sm_print + 1;
                        end
                    end
                end
            end
        end
    end

    // ========================================================================
    // 任务
    // ========================================================================
    task do_reset;
        begin
            rst_n = 1'b0;
            src_start = 1'b0; src_valid = 1'b0;
            repeat (5) @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(negedge clk);
        end
    endtask

    task clear_maps;
        integer k;
        begin
            for (k = 0; k < 640*480; k = k + 1) big_seen[k] = 1'b0;
            for (k = 0; k < 64*48;   k = k + 1) sm_seen[k]  = 1'b0;
            for (k = 0; k < 480; k = k + 1) big_row_cnt[k] = 0;
            for (k = 0; k < 640; k = k + 1) big_col_cnt[k] = 0;
        end
    endtask

    // 按 BMP 到达顺序灌入一帧（自顶向下: src_y 递增；自底向上: 递减）
    task send_frame;
        integer ry, rx, yy;
        begin
            @(negedge clk);
            src_start = 1'b1;
            src_w = SW[15:0];
            src_h = SH[15:0];
            @(negedge clk);
            src_start = 1'b0;
            while (!(big_ok && sm_ok)) @(negedge clk); // 两个实例都算出配置后再灌像素
            for (ry = 0; ry < SH; ry = ry + 1) begin
                yy = TD ? ry : (SH - 1 - ry);
                for (rx = 0; rx < SW; rx = rx + 1) begin
                    @(negedge clk);
                    src_valid  = 1'b1;
                    src_rgb565 = src_color(rx, yy);
                    src_y      = yy[15:0];
                end
            end
            @(negedge clk);
            src_valid = 1'b0;
            repeat (4) @(negedge clk);
        end
    endtask

    task begin_case;
        input [511:0] name;
        input integer sw, sh, td, ew, eh, eox, eoy, poschk;
        begin
            $display("\n--- %0s  src=%0dx%0d top_down=%0d pos_chk=%0d ---",
                     name, sw, sh, td, poschk);
            do_reset; clear_maps;
            SW=sw; SH=sh; TD=td; EW=ew; EH=eh; EOX=eox; EOY=eoy; POS_CHK=poschk;
            big_cnt=0; big_coord_err=0; big_dup_err=0; big_print=0;
            sm_cnt=0;  sm_coord_err=0;  sm_dup_err=0;  sm_pos_err=0; sm_print=0;
        end
    endtask

    // 大容器用例: 几何
    task run_big;
        input [511:0] name;
        input integer sw, sh, td, ew, eh, eox, eoy;
        integer r, bad;
        begin
            CHK_BIG = 1; CHK_SM = 0;
            begin_case(name, sw, sh, td, ew, eh, eox, eoy, 0);
            send_frame;

            chk(big_ok === 1'b1,    "big: cfg_ok raised");
            chk(big_ow == ew,       "big: out_w");
            chk(big_oh == eh,       "big: out_h");
            chk(big_ox == eox,      "big: out_off_x");
            chk(big_oy == eoy,      "big: out_off_y");
            chk(big_pix == ew*eh,   "big: out_pixels");
            chk(big_cnt == ew*eh,   "big: dst pixel count");
            chk(big_coord_err == 0, "big: no coord out of window");
            chk(big_dup_err == 0,   "big: no duplicate target pixel");

            bad = 0;
            for (r = eoy; r < eoy + eh; r = r + 1)
                if (big_row_cnt[r] != ew) bad = bad + 1;
            chk(bad == 0, "big: every row fully occupied");

            bad = 0;
            for (r = eox; r < eox + ew; r = r + 1)
                if (big_col_cnt[r] != eh) bad = bad + 1;
            chk(bad == 0, "big: every column fully occupied");

            $display("  got=%0d/%0d coord=%0d dup=%0d",
                     big_cnt, ew*eh, big_coord_err, big_dup_err);
        end
    endtask

    // 小容器用例: 采样来源 + 行序
    task run_sm;
        input [511:0] name;
        input integer sw, sh, td, ew, eh, eox, eoy, poschk;
        begin
            CHK_BIG = 0; CHK_SM = 1;
            begin_case(name, sw, sh, td, ew, eh, eox, eoy, poschk);
            send_frame;

            chk(sm_ok === 1'b1,    "sm: cfg_ok raised");
            chk(sm_ow == ew,       "sm: out_w");
            chk(sm_oh == eh,       "sm: out_h");
            chk(sm_ox == eox,      "sm: out_off_x");
            chk(sm_oy == eoy,      "sm: out_off_y");
            chk(sm_pix == ew*eh,   "sm: out_pixels");
            chk(sm_cnt == ew*eh,   "sm: dst pixel count");
            chk(sm_coord_err == 0, "sm: no coord out of window");
            chk(sm_dup_err == 0,   "sm: no duplicate target pixel");
            if (poschk) chk(sm_pos_err == 0, "sm: exact source sample + row order");
            // 目标宽必须是 8 的倍数：行字数（out_w/2）与行首字地址
            // （out_off_x/2）都要落在 4 字边界上，否则仲裁器的四字突发组跨行错位
            chk((sm_ow % 8) == 0,  "sm: out_w is 8-pixel aligned");
            chk((sm_ox % 8) == 0,  "sm: out_off_x is 8-pixel aligned");

            $display("  got=%0d/%0d coord=%0d dup=%0d pos=%0d",
                     sm_cnt, ew*eh, sm_coord_err, sm_dup_err, sm_pos_err);
        end
    endtask

    // Zero dimensions are malformed BMP metadata.  Exercise them after a
    // valid frame so a stale configuration cannot masquerade as a new frame.
    task check_invalid_dimensions;
        input [511:0] name;
        input integer iw, ih;
        integer sample;
        begin
            $display("\n--- %0s  invalid src=%0dx%0d ---", name, iw, ih);
            @(negedge clk);
            src_start = 1'b1;
            src_w = iw[15:0];
            src_h = ih[15:0];
            src_valid = 1'b0;
            @(negedge clk);
            src_start = 1'b0;
            repeat (8) @(negedge clk);

            chk(big_ok === 1'b0,    "invalid: big cfg_ok stays low");
            chk(sm_ok === 1'b0,     "invalid: small cfg_ok stays low");
            chk(big_ow == 16'd0 && big_oh == 16'd0 && big_ox == 16'd0 &&
                big_oy == 16'd0 && big_pix == 32'd0,
                "invalid: big geometry is cleared");
            chk(sm_ow == 16'd0 && sm_oh == 16'd0 && sm_ox == 16'd0 &&
                sm_oy == 16'd0 && sm_pix == 32'd0,
                "invalid: small geometry is cleared");
            chk(big_valid === 1'b0 && sm_valid === 1'b0,
                "invalid: no destination pixel is emitted");

            for (sample = 0; sample < 8; sample = sample + 1) begin
                @(negedge clk);
                src_valid = 1'b1;
                src_y = sample[15:0];
                src_rgb565 = 16'hF81F;
                @(posedge clk);
                #1;
                chk(big_ok === 1'b0 && sm_ok === 1'b0 &&
                    big_valid === 1'b0 && sm_valid === 1'b0,
                    "invalid: malformed frame stays disabled and emits no pixels");
            end
            @(negedge clk);
            src_valid = 1'b0;
        end
    endtask

    // ========================================================================
    // 主流程
    // ========================================================================
    initial begin
        $display("=== tb_img_scaler start ===");
        CHK_BIG = 0; CHK_SM = 0; POS_CHK = 0;
        big_cnt=0; big_coord_err=0; big_dup_err=0; big_print=0;
        sm_cnt=0;  sm_coord_err=0;  sm_dup_err=0;  sm_pos_err=0; sm_print=0;

        // ---- 大容器: 真实尺寸下的几何 ----
        run_big("S01 vga-native",   640, 480, 0, 640, 480,   0,   0);
        run_big("S02 qvga-center",  320, 240, 0, 320, 240, 160, 120);
        run_big("S03 wide-shrink", 1280, 480, 0, 640, 240,   0, 120);
        run_big("S04 tall-shrink",  480, 960, 0, 240, 480, 200,   0);
        run_big("S05 top-down",     320, 240, 1, 320, 240, 160, 120);
        run_big("S06 bottom-up",   1280, 480, 0, 640, 240,   0, 120);

        // ---- 小容器: 采样来源与行序（pos_chk=1）----
        run_sm("T01 shrink-64x48",  128,  96, 0,  64,  48,   0,   0, 1);
        run_sm("T02 shrink-24x48",   48,  96, 0,  24,  48,  16,   0, 1);
        run_sm("T03 center-1to1",    32,  24, 0,  32,  24,  16,  12, 1);
        // T04: 96×64 → 以宽为准 dst_w=64、dst_h=64*64/96=42（非 2:1 比例）
        run_sm("T04 ratio-3to2",     96,  64, 0,  64,  42,   0,   3, 1);
        run_sm("T05 top-down",      128,  96, 1,  64,  48,   0,   0, 1);
        run_sm("T06 bottom-up",     128,  96, 0,  64,  48,   0,   0, 1);
        // T07: 45×64 → 以高为准，自然 dst_w=45*48/64=33（奇数）→ 强制 32
        //      POS_CHK=0: 发生钳位，floor 模型不适用，只查几何与偶数约束
        run_sm("T07 odd-to-even",    45,  64, 0,  32,  48,  16,   0, 0);
        // T08: 90×80 → 以高为准，自然 dst_w=90*48/80=54，54 是偶数但**不是 8 的倍数**
        //      → 截到 48。这是唯一能区分「偶数对齐」与「8 像素对齐」的用例：
        //      若只做偶数对齐，dst_w 会停在 54，行字数 27 不是 4 的倍数，
        //      仲裁器四字突发组跨行、整帧错位（真机上表现为图像撕裂）。
        //      POS_CHK=1: 截断后 dst_w 与 c_step 仍一致，floor 模型照样成立。
        run_sm("T08 8px-align-trunc", 90, 80, 0,  48,  48,   8,   0, 1);

        // The first invalid frame follows a valid one and therefore catches
        // stale out_cfg_ok/out_pixels, not just reset-time handling.
        check_invalid_dimensions("T09 zero-width", 0, 96);
        check_invalid_dimensions("T10 zero-height", 128, 0);

        $display("\nSUMMARY: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("ALL CHECKS PASSED: img_scaler");
        else             $display("CHECKS FAILED");
        $finish;
    end

endmodule

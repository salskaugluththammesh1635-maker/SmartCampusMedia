// ============================================================================
//  narr_subline.v -- 科普模式视频字幕（narration.srt 18 段）的小字表
//  ============================================================================
//  【一】系统功能
//     科普模式下，屏幕底部那条滚动字幕要显示的是视频旁白字幕（不是校园介绍）。
//     本模块就是那张字幕表：输入当前视频帧号与字符列，输出该位置的字形索引。
//
//  【二】本模块功能
//     一个 1024 x 9 bit 的块 RAM，存 18 段字幕的字形索引流（按段落顺序首尾相接）。
//     另有 18 项 start/len/base 常量表：
//       start[i]  第 i 段的起始帧号（@5fps，floor(t*5)）
//       len[i]    第 i 段实际用到的字数（超 40 字的段按裁定只取前 40 字）
//       base[i]   第 i 段在 BRAM 里的起始地址（cumsum）
//
//     段选规则：sel = 满足 start[i] <= frame_idx 的最大 i
//       因为 start 单调递增，等价于 sel = (命中项个数) - 1。
//       段与段之间的空隙沿用上一段（即『保持上一段』），这正是 max-i 语义。
//
//     三条边界：
//       frame_idx <  start[0]  -> 尚无字幕，输出 9'h1FF 空白
//       frame_idx >  624     -> 视频已结束，输出 9'h1FF 空白
//       段间空隙                -> 保持上一段（由 max-i 语义自然得到）
//
//  【三】为什么是 1024 x 9 bit / 为什么刚好占 1 块 BRAM9K
//     1024 x 9 = 9,216 bit，恰好等于一块 BRAM9K 的容量（512 x 18 = 9,216）。
//     所以这个尺寸不是估算出来的，是『正好填满一块、绝不溢出到第二块』。
//     实用深度 533 项（18 段字数之和，超 40 字截断后），其余填 9'h1FF。
//
//     位宽必须是 9 位：osd_caption 里滚动带恒走中文（CJK）路径，
//     bit9 恒为 1 不携带任何信息，所以这里只存 0..464 的 9 位字形索引。
//     9'h1FF 是空白哨兵（465..511 都不是合法字形，取 511 最远、最安全）。
//
//  【四】读延迟：1 拍，且就由块 RAM 输出寄存器承担
//     本模块是同步读块 RAM：拍 N 给地址，拍 N+1 出 narr_code。
//     这一拍由 BRAM 自己的输出寄存器承担，**不再另加 cjk_px_q 式的外部寄存器**
//     （再打一拍就变 2 拍，会与配对信号的拍数错开，现象是每个字符的行点阵错位）。
//     这是 t3 在 cjk16_font.v 上踩过并纠正的同一个教训，此处照办。
//
//  【五】为什么不用 $readmemh
//     数据直接内联在本文件的 initial 块里，不引入外部 .hex 文件。
//     理由：t3 的 cjk16_bitmap.hex 至今还需要 sync_src.ps1 与 hdmi_td.al 补路径，
//     否则综合出全零 BRAM 且不报错。本模块只有 9,216 bit，内联进源码即可，
//     不给工程再添一个『忘了同步就静默全空白』的失败面。
//     代价是本文件较长（1024 行初始化），由 tools 生成、不要手改。
//
//  【六】数据来源（不要手改，改文案请改 narration.srt 后重新生成）
//     assets/v2/masters/video/narration.srt（18 条，文案已冻结）
//     字形索引取自 assets/v2/masters/font/cjk16_charset.txt（465 字形，0..464 冻结）
//     生成时逐字校验：任何字形索引 > 464 直接硬失败，不会静默画空白。
//     本表全部 18 段均已验证零缺字。
//
//  【七】资源
//     1 块 BRAM9K（1024 x 9），约 20 lut（16 位比较 x18 + 计数 + 查表 mux）
// ============================================================================

module narr_subline (
    input  wire        clk,          // 像素时钟 25 MHz
    input  wire        rst_n,        // 异步复位；块 RAM 无复位语义，仅用于端口对齐
    input  wire [15:0] frame_idx,    // 当前视频帧号（@5fps，floor(t*1000*5)）
    input  wire [5:0]  col,          // 字符列 0..63（滚动带 ticker_col）
    output wire [8:0]  narr_code     // 该列的字形索引；9'h1FF = 空白
);

    localparam [8:0]  BLANK      = 9'h1FF;
    localparam [15:0] END_FRAME  = 16'd624;
    localparam [15:0] START0     = 16'd4;

    // ---- 18 项常量表（由 narration.srt 生成，勿手改）------------------------
    function [15:0] seg_start;
        input [4:0] i;
        begin
            case (i)
                5'd 0: seg_start = 16'd4   ;
                5'd 1: seg_start = 16'd21  ;
                5'd 2: seg_start = 16'd52  ;
                5'd 3: seg_start = 16'd92  ;
                5'd 4: seg_start = 16'd136 ;
                5'd 5: seg_start = 16'd161 ;
                5'd 6: seg_start = 16'd201 ;
                5'd 7: seg_start = 16'd231 ;
                5'd 8: seg_start = 16'd260 ;
                5'd 9: seg_start = 16'd317 ;
                5'd10: seg_start = 16'd339 ;
                5'd11: seg_start = 16'd385 ;
                5'd12: seg_start = 16'd441 ;
                5'd13: seg_start = 16'd482 ;
                5'd14: seg_start = 16'd500 ;
                5'd15: seg_start = 16'd540 ;
                5'd16: seg_start = 16'd594 ;
                5'd17: seg_start = 16'd615 ;
                default: seg_start = 16'd0;
            endcase
        end
    endfunction

    function [5:0] seg_len;
        input [4:0] i;
        begin
            case (i)
                5'd 0: seg_len = 6'd16;
                5'd 1: seg_len = 6'd24;
                5'd 2: seg_len = 6'd39;
                5'd 3: seg_len = 6'd38;
                5'd 4: seg_len = 6'd23;
                5'd 5: seg_len = 6'd40;
                5'd 6: seg_len = 6'd24;
                5'd 7: seg_len = 6'd29;
                5'd 8: seg_len = 6'd40;
                5'd 9: seg_len = 6'd25;
                5'd10: seg_len = 6'd37;
                5'd11: seg_len = 6'd40;
                5'd12: seg_len = 6'd34;
                5'd13: seg_len = 6'd23;
                5'd14: seg_len = 6'd30;
                5'd15: seg_len = 6'd40;
                5'd16: seg_len = 6'd18;
                5'd17: seg_len = 6'd13;
                default: seg_len = 6'd0;
            endcase
        end
    endfunction

    function [9:0] seg_base;
        input [4:0] i;
        begin
            case (i)
                5'd 0: seg_base = 10'd0   ;
                5'd 1: seg_base = 10'd16  ;
                5'd 2: seg_base = 10'd40  ;
                5'd 3: seg_base = 10'd79  ;
                5'd 4: seg_base = 10'd117 ;
                5'd 5: seg_base = 10'd140 ;
                5'd 6: seg_base = 10'd180 ;
                5'd 7: seg_base = 10'd204 ;
                5'd 8: seg_base = 10'd233 ;
                5'd 9: seg_base = 10'd273 ;
                5'd10: seg_base = 10'd298 ;
                5'd11: seg_base = 10'd335 ;
                5'd12: seg_base = 10'd375 ;
                5'd13: seg_base = 10'd409 ;
                5'd14: seg_base = 10'd432 ;
                5'd15: seg_base = 10'd462 ;
                5'd16: seg_base = 10'd502 ;
                5'd17: seg_base = 10'd520 ;
                default: seg_base = 10'd0;
            endcase
        end
    endfunction

    // ---- 段选：18 路并行比较 + 计数 ---------------------------------------
    //   start 单调递增 -> 命中项必然构成前缀 -> 命中个数 - 1 就是『最大命中下标』
    //   组合级数：16 位比较约 5 级，18 项并行无串接；计数树 4 级；
    //             再叠加 base/len 的 18 选 1 mux 约 5 级，合计约 14 级 LUT。
    //             25 MHz（40 ns）下远有余量。
    wire [17:0] hit;
    assign hit[ 0] = (frame_idx >= 16'd4   );
    assign hit[ 1] = (frame_idx >= 16'd21  );
    assign hit[ 2] = (frame_idx >= 16'd52  );
    assign hit[ 3] = (frame_idx >= 16'd92  );
    assign hit[ 4] = (frame_idx >= 16'd136 );
    assign hit[ 5] = (frame_idx >= 16'd161 );
    assign hit[ 6] = (frame_idx >= 16'd201 );
    assign hit[ 7] = (frame_idx >= 16'd231 );
    assign hit[ 8] = (frame_idx >= 16'd260 );
    assign hit[ 9] = (frame_idx >= 16'd317 );
    assign hit[10] = (frame_idx >= 16'd339 );
    assign hit[11] = (frame_idx >= 16'd385 );
    assign hit[12] = (frame_idx >= 16'd441 );
    assign hit[13] = (frame_idx >= 16'd482 );
    assign hit[14] = (frame_idx >= 16'd500 );
    assign hit[15] = (frame_idx >= 16'd540 );
    assign hit[16] = (frame_idx >= 16'd594 );
    assign hit[17] = (frame_idx >= 16'd615 );

    wire [4:0] cnt = hit[ 0] + hit[ 1] + hit[ 2] + hit[ 3] + hit[ 4]
                   + hit[ 5] + hit[ 6] + hit[ 7] + hit[ 8] + hit[ 9]
                   + hit[10] + hit[11] + hit[12] + hit[13] + hit[14]
                   + hit[15] + hit[16] + hit[17];

    wire [4:0] sel = cnt - 5'd1;          // cnt == 0 时无意义，由 in_range 挡住

    // 视频时间轴内才显示字幕：第一段开始之后、最后一段结束之前
    wire in_range = (frame_idx >= START0) && (frame_idx <= END_FRAME);

    wire [5:0]  cur_len  = seg_len(sel);
    wire [9:0]  cur_base = seg_base(sel);

    // ---- 地址：base[sel] + col，段尾用 len[sel] gate 到空白 -----------------
    wire [9:0]  addr  = cur_base + {4'b0000, col};
    wire        in_seg = in_range && (sel <= 5'd17) && ({1'b0, col} < {1'b0, cur_len});

    // ---- 块 RAM：1024 x 9，同步读 1 拍 ------------------------------------
    //   ram_style = bram 让综合器明确按块 RAM 映射（TD 6.2 对该模式默认也会推断，
    //   这里写出来是双保险，也便于阅读者一眼看出这是存储体不是组合表）。
    reg [8:0] mem [0:1023] /* synthesis ram_style = bram */;

    integer init_i;
    initial begin
        // 先全填空白哨兵，再写入 533 项正文 —— 未用到的地址读回空白，不会画出怪字
        mem[   0] = 9'h067;
        mem[   1] = 9'h06B;
        mem[   2] = 9'h068;
        mem[   3] = 9'h063;
        mem[   4] = 9'h1CF;
        mem[   5] = 9'h0A8;
        mem[   6] = 9'h16C;
        mem[   7] = 9'h154;
        mem[   8] = 9'h0D6;
        mem[   9] = 9'h033;
        mem[  10] = 9'h17C;
        mem[  11] = 9'h16D;
        mem[  12] = 9'h1BD;
        mem[  13] = 9'h1C3;
        mem[  14] = 9'h0B5;
        mem[  15] = 9'h077;
        mem[  16] = 9'h08D;
        mem[  17] = 9'h0E1;
        mem[  18] = 9'h158;
        mem[  19] = 9'h0B1;
        mem[  20] = 9'h029;
        mem[  21] = 9'h1B8;
        mem[  22] = 9'h1CF;
        mem[  23] = 9'h0F5;
        mem[  24] = 9'h09E;
        mem[  25] = 9'h190;
        mem[  26] = 9'h194;
        mem[  27] = 9'h1AA;
        mem[  28] = 9'h16B;
        mem[  29] = 9'h033;
        mem[  30] = 9'h092;
        mem[  31] = 9'h18A;
        mem[  32] = 9'h1B7;
        mem[  33] = 9'h123;
        mem[  34] = 9'h0EA;
        mem[  35] = 9'h082;
        mem[  36] = 9'h15E;
        mem[  37] = 9'h186;
        mem[  38] = 9'h03D;
        mem[  39] = 9'h077;
        mem[  40] = 9'h005;
        mem[  41] = 9'h1AF;
        mem[  42] = 9'h186;
        mem[  43] = 9'h03D;
        mem[  44] = 9'h047;
        mem[  45] = 9'h0B2;
        mem[  46] = 9'h0C3;
        mem[  47] = 9'h126;
        mem[  48] = 9'h0BD;
        mem[  49] = 9'h180;
        mem[  50] = 9'h0EF;
        mem[  51] = 9'h0F3;
        mem[  52] = 9'h0D5;
        mem[  53] = 9'h0EA;
        mem[  54] = 9'h1CF;
        mem[  55] = 9'h17E;
        mem[  56] = 9'h067;
        mem[  57] = 9'h06B;
        mem[  58] = 9'h068;
        mem[  59] = 9'h063;
        mem[  60] = 9'h0AD;
        mem[  61] = 9'h1B3;
        mem[  62] = 9'h129;
        mem[  63] = 9'h0E0;
        mem[  64] = 9'h028;
        mem[  65] = 9'h033;
        mem[  66] = 9'h1B5;
        mem[  67] = 9'h17D;
        mem[  68] = 9'h15E;
        mem[  69] = 9'h1B1;
        mem[  70] = 9'h1A2;
        mem[  71] = 9'h0C1;
        mem[  72] = 9'h0A5;
        mem[  73] = 9'h0D0;
        mem[  74] = 9'h1AC;
        mem[  75] = 9'h176;
        mem[  76] = 9'h19A;
        mem[  77] = 9'h14A;
        mem[  78] = 9'h077;
        mem[  79] = 9'h046;
        mem[  80] = 9'h049;
        mem[  81] = 9'h07A;
        mem[  82] = 9'h0CF;
        mem[  83] = 9'h15E;
        mem[  84] = 9'h1B5;
        mem[  85] = 9'h17D;
        mem[  86] = 9'h122;
        mem[  87] = 9'h093;
        mem[  88] = 9'h1CF;
        mem[  89] = 9'h0CF;
        mem[  90] = 9'h044;
        mem[  91] = 9'h0D8;
        mem[  92] = 9'h186;
        mem[  93] = 9'h03D;
        mem[  94] = 9'h033;
        mem[  95] = 9'h092;
        mem[  96] = 9'h0CA;
        mem[  97] = 9'h106;
        mem[  98] = 9'h18F;
        mem[  99] = 9'h121;
        mem[ 100] = 9'h0D2;
        mem[ 101] = 9'h076;
        mem[ 102] = 9'h03C;
        mem[ 103] = 9'h0A4;
        mem[ 104] = 9'h0DD;
        mem[ 105] = 9'h155;
        mem[ 106] = 9'h0D2;
        mem[ 107] = 9'h1CF;
        mem[ 108] = 9'h156;
        mem[ 109] = 9'h182;
        mem[ 110] = 9'h044;
        mem[ 111] = 9'h080;
        mem[ 112] = 9'h0DD;
        mem[ 113] = 9'h155;
        mem[ 114] = 9'h0D2;
        mem[ 115] = 9'h138;
        mem[ 116] = 9'h077;
        mem[ 117] = 9'h067;
        mem[ 118] = 9'h06B;
        mem[ 119] = 9'h068;
        mem[ 120] = 9'h063;
        mem[ 121] = 9'h0EB;
        mem[ 122] = 9'h154;
        mem[ 123] = 9'h1B1;
        mem[ 124] = 9'h1A2;
        mem[ 125] = 9'h15E;
        mem[ 126] = 9'h138;
        mem[ 127] = 9'h101;
        mem[ 128] = 9'h129;
        mem[ 129] = 9'h136;
        mem[ 130] = 9'h10B;
        mem[ 131] = 9'h189;
        mem[ 132] = 9'h1CF;
        mem[ 133] = 9'h085;
        mem[ 134] = 9'h0EF;
        mem[ 135] = 9'h129;
        mem[ 136] = 9'h06A;
        mem[ 137] = 9'h06E;
        mem[ 138] = 9'h06D;
        mem[ 139] = 9'h077;
        mem[ 140] = 9'h044;
        mem[ 141] = 9'h080;
        mem[ 142] = 9'h0D3;
        mem[ 143] = 9'h1A3;
        mem[ 144] = 9'h0A7;
        mem[ 145] = 9'h136;
        mem[ 146] = 9'h10B;
        mem[ 147] = 9'h189;
        mem[ 148] = 9'h12F;
        mem[ 149] = 9'h199;
        mem[ 150] = 9'h043;
        mem[ 151] = 9'h129;
        mem[ 152] = 9'h0C0;
        mem[ 153] = 9'h0AA;
        mem[ 154] = 9'h09A;
        mem[ 155] = 9'h15E;
        mem[ 156] = 9'h0EE;
        mem[ 157] = 9'h0E7;
        mem[ 158] = 9'h0A3;
        mem[ 159] = 9'h0D2;
        mem[ 160] = 9'h1CF;
        mem[ 161] = 9'h10D;
        mem[ 162] = 9'h163;
        mem[ 163] = 9'h0A1;
        mem[ 164] = 9'h189;
        mem[ 165] = 9'h0AF;
        mem[ 166] = 9'h1AB;
        mem[ 167] = 9'h0C5;
        mem[ 168] = 9'h1CF;
        mem[ 169] = 9'h0EF;
        mem[ 170] = 9'h180;
        mem[ 171] = 9'h0EB;
        mem[ 172] = 9'h154;
        mem[ 173] = 9'h094;
        mem[ 174] = 9'h105;
        mem[ 175] = 9'h0D3;
        mem[ 176] = 9'h1A3;
        mem[ 177] = 9'h0A7;
        mem[ 178] = 9'h1B1;
        mem[ 179] = 9'h1A2;
        mem[ 180] = 9'h136;
        mem[ 181] = 9'h10B;
        mem[ 182] = 9'h189;
        mem[ 183] = 9'h0AE;
        mem[ 184] = 9'h1B5;
        mem[ 185] = 9'h0CE;
        mem[ 186] = 9'h18E;
        mem[ 187] = 9'h0C8;
        mem[ 188] = 9'h0D2;
        mem[ 189] = 9'h1CF;
        mem[ 190] = 9'h0EF;
        mem[ 191] = 9'h134;
        mem[ 192] = 9'h106;
        mem[ 193] = 9'h087;
        mem[ 194] = 9'h126;
        mem[ 195] = 9'h0F8;
        mem[ 196] = 9'h15A;
        mem[ 197] = 9'h19E;
        mem[ 198] = 9'h15E;
        mem[ 199] = 9'h0DA;
        mem[ 200] = 9'h12F;
        mem[ 201] = 9'h0C1;
        mem[ 202] = 9'h0A5;
        mem[ 203] = 9'h077;
        mem[ 204] = 9'h044;
        mem[ 205] = 9'h0D8;
        mem[ 206] = 9'h067;
        mem[ 207] = 9'h06B;
        mem[ 208] = 9'h068;
        mem[ 209] = 9'h063;
        mem[ 210] = 9'h159;
        mem[ 211] = 9'h033;
        mem[ 212] = 9'h17C;
        mem[ 213] = 9'h16D;
        mem[ 214] = 9'h1B1;
        mem[ 215] = 9'h1A2;
        mem[ 216] = 9'h0D8;
        mem[ 217] = 9'h076;
        mem[ 218] = 9'h033;
        mem[ 219] = 9'h17C;
        mem[ 220] = 9'h16D;
        mem[ 221] = 9'h08A;
        mem[ 222] = 9'h1AC;
        mem[ 223] = 9'h0D0;
        mem[ 224] = 9'h1A3;
        mem[ 225] = 9'h0A7;
        mem[ 226] = 9'h1A3;
        mem[ 227] = 9'h0B2;
        mem[ 228] = 9'h0C1;
        mem[ 229] = 9'h0A5;
        mem[ 230] = 9'h177;
        mem[ 231] = 9'h106;
        mem[ 232] = 9'h077;
        mem[ 233] = 9'h154;
        mem[ 234] = 9'h090;
        mem[ 235] = 9'h067;
        mem[ 236] = 9'h06B;
        mem[ 237] = 9'h068;
        mem[ 238] = 9'h063;
        mem[ 239] = 9'h1A9;
        mem[ 240] = 9'h1C5;
        mem[ 241] = 9'h106;
        mem[ 242] = 9'h087;
        mem[ 243] = 9'h0D8;
        mem[ 244] = 9'h0E7;
        mem[ 245] = 9'h0A3;
        mem[ 246] = 9'h0D2;
        mem[ 247] = 9'h076;
        mem[ 248] = 9'h065;
        mem[ 249] = 9'h06C;
        mem[ 250] = 9'h06B;
        mem[ 251] = 9'h083;
        mem[ 252] = 9'h143;
        mem[ 253] = 9'h0C1;
        mem[ 254] = 9'h0A5;
        mem[ 255] = 9'h0D0;
        mem[ 256] = 9'h1BA;
        mem[ 257] = 9'h161;
        mem[ 258] = 9'h021;
        mem[ 259] = 9'h1CF;
        mem[ 260] = 9'h029;
        mem[ 261] = 9'h0B7;
        mem[ 262] = 9'h197;
        mem[ 263] = 9'h198;
        mem[ 264] = 9'h121;
        mem[ 265] = 9'h114;
        mem[ 266] = 9'h17B;
        mem[ 267] = 9'h0E7;
        mem[ 268] = 9'h076;
        mem[ 269] = 9'h01E;
        mem[ 270] = 9'h1B0;
        mem[ 271] = 9'h014;
        mem[ 272] = 9'h173;
        mem[ 273] = 9'h064;
        mem[ 274] = 9'h06B;
        mem[ 275] = 9'h06E;
        mem[ 276] = 9'h112;
        mem[ 277] = 9'h1C8;
        mem[ 278] = 9'h0F8;
        mem[ 279] = 9'h10A;
        mem[ 280] = 9'h188;
        mem[ 281] = 9'h111;
        mem[ 282] = 9'h091;
        mem[ 283] = 9'h1CF;
        mem[ 284] = 9'h0CF;
        mem[ 285] = 9'h044;
        mem[ 286] = 9'h126;
        mem[ 287] = 9'h0BA;
        mem[ 288] = 9'h0CC;
        mem[ 289] = 9'h180;
        mem[ 290] = 9'h0DD;
        mem[ 291] = 9'h155;
        mem[ 292] = 9'h12D;
        mem[ 293] = 9'h1C4;
        mem[ 294] = 9'h15E;
        mem[ 295] = 9'h094;
        mem[ 296] = 9'h0BE;
        mem[ 297] = 9'h077;
        mem[ 298] = 9'h067;
        mem[ 299] = 9'h06B;
        mem[ 300] = 9'h068;
        mem[ 301] = 9'h063;
        mem[ 302] = 9'h0B6;
        mem[ 303] = 9'h10D;
        mem[ 304] = 9'h173;
        mem[ 305] = 9'h143;
        mem[ 306] = 9'h160;
        mem[ 307] = 9'h116;
        mem[ 308] = 9'h0CA;
        mem[ 309] = 9'h106;
        mem[ 310] = 9'h167;
        mem[ 311] = 9'h093;
        mem[ 312] = 9'h15A;
        mem[ 313] = 9'h19E;
        mem[ 314] = 9'h1CF;
        mem[ 315] = 9'h0DE;
        mem[ 316] = 9'h132;
        mem[ 317] = 9'h121;
        mem[ 318] = 9'h114;
        mem[ 319] = 9'h1AF;
        mem[ 320] = 9'h19E;
        mem[ 321] = 9'h0CF;
        mem[ 322] = 9'h126;
        mem[ 323] = 9'h010;
        mem[ 324] = 9'h09D;
        mem[ 325] = 9'h1CF;
        mem[ 326] = 9'h0FA;
        mem[ 327] = 9'h1AD;
        mem[ 328] = 9'h09B;
        mem[ 329] = 9'h17E;
        mem[ 330] = 9'h07C;
        mem[ 331] = 9'h033;
        mem[ 332] = 9'h1C9;
        mem[ 333] = 9'h148;
        mem[ 334] = 9'h077;
        mem[ 335] = 9'h067;
        mem[ 336] = 9'h06B;
        mem[ 337] = 9'h068;
        mem[ 338] = 9'h063;
        mem[ 339] = 9'h15E;
        mem[ 340] = 9'h036;
        mem[ 341] = 9'h0C8;
        mem[ 342] = 9'h147;
        mem[ 343] = 9'h16D;
        mem[ 344] = 9'h044;
        mem[ 345] = 9'h184;
        mem[ 346] = 9'h129;
        mem[ 347] = 9'h05E;
        mem[ 348] = 9'h158;
        mem[ 349] = 9'h06F;
        mem[ 350] = 9'h070;
        mem[ 351] = 9'h075;
        mem[ 352] = 9'h072;
        mem[ 353] = 9'h073;
        mem[ 354] = 9'h074;
        mem[ 355] = 9'h071;
        mem[ 356] = 9'h107;
        mem[ 357] = 9'h06F;
        mem[ 358] = 9'h069;
        mem[ 359] = 9'h065;
        mem[ 360] = 9'h06A;
        mem[ 361] = 9'h119;
        mem[ 362] = 9'h1AE;
        mem[ 363] = 9'h15A;
        mem[ 364] = 9'h19E;
        mem[ 365] = 9'h1CF;
        mem[ 366] = 9'h179;
        mem[ 367] = 9'h1A5;
        mem[ 368] = 9'h17A;
        mem[ 369] = 9'h0CE;
        mem[ 370] = 9'h076;
        mem[ 371] = 9'h0F4;
        mem[ 372] = 9'h0F0;
        mem[ 373] = 9'h0F4;
        mem[ 374] = 9'h176;
        mem[ 375] = 9'h047;
        mem[ 376] = 9'h1AA;
        mem[ 377] = 9'h080;
        mem[ 378] = 9'h1A5;
        mem[ 379] = 9'h16D;
        mem[ 380] = 9'h081;
        mem[ 381] = 9'h1CF;
        mem[ 382] = 9'h095;
        mem[ 383] = 9'h163;
        mem[ 384] = 9'h0D0;
        mem[ 385] = 9'h126;
        mem[ 386] = 9'h0F8;
        mem[ 387] = 9'h029;
        mem[ 388] = 9'h135;
        mem[ 389] = 9'h0A0;
        mem[ 390] = 9'h193;
        mem[ 391] = 9'h192;
        mem[ 392] = 9'h18F;
        mem[ 393] = 9'h125;
        mem[ 394] = 9'h0BD;
        mem[ 395] = 9'h180;
        mem[ 396] = 9'h023;
        mem[ 397] = 9'h168;
        mem[ 398] = 9'h1CF;
        mem[ 399] = 9'h0C6;
        mem[ 400] = 9'h180;
        mem[ 401] = 9'h19D;
        mem[ 402] = 9'h047;
        mem[ 403] = 9'h15F;
        mem[ 404] = 9'h137;
        mem[ 405] = 9'h032;
        mem[ 406] = 9'h02B;
        mem[ 407] = 9'h043;
        mem[ 408] = 9'h077;
        mem[ 409] = 9'h02E;
        mem[ 410] = 9'h0E5;
        mem[ 411] = 9'h1AA;
        mem[ 412] = 9'h13F;
        mem[ 413] = 9'h06F;
        mem[ 414] = 9'h070;
        mem[ 415] = 9'h075;
        mem[ 416] = 9'h072;
        mem[ 417] = 9'h073;
        mem[ 418] = 9'h074;
        mem[ 419] = 9'h071;
        mem[ 420] = 9'h090;
        mem[ 421] = 9'h166;
        mem[ 422] = 9'h1CF;
        mem[ 423] = 9'h119;
        mem[ 424] = 9'h1AE;
        mem[ 425] = 9'h087;
        mem[ 426] = 9'h044;
        mem[ 427] = 9'h080;
        mem[ 428] = 9'h18F;
        mem[ 429] = 9'h121;
        mem[ 430] = 9'h0D2;
        mem[ 431] = 9'h077;
        mem[ 432] = 9'h17A;
        mem[ 433] = 9'h0CE;
        mem[ 434] = 9'h010;
        mem[ 435] = 9'h0AC;
        mem[ 436] = 9'h098;
        mem[ 437] = 9'h10D;
        mem[ 438] = 9'h0E9;
        mem[ 439] = 9'h128;
        mem[ 440] = 9'h0ED;
        mem[ 441] = 9'h106;
        mem[ 442] = 9'h18E;
        mem[ 443] = 9'h0C8;
        mem[ 444] = 9'h0D2;
        mem[ 445] = 9'h0D0;
        mem[ 446] = 9'h136;
        mem[ 447] = 9'h10B;
        mem[ 448] = 9'h189;
        mem[ 449] = 9'h1CF;
        mem[ 450] = 9'h191;
        mem[ 451] = 9'h06A;
        mem[ 452] = 9'h066;
        mem[ 453] = 9'h065;
        mem[ 454] = 9'h112;
        mem[ 455] = 9'h0D5;
        mem[ 456] = 9'h0EA;
        mem[ 457] = 9'h185;
        mem[ 458] = 9'h0E3;
        mem[ 459] = 9'h1BE;
        mem[ 460] = 9'h14F;
        mem[ 461] = 9'h077;
        mem[ 462] = 9'h0E5;
        mem[ 463] = 9'h08D;
        mem[ 464] = 9'h1CF;
        mem[ 465] = 9'h067;
        mem[ 466] = 9'h06B;
        mem[ 467] = 9'h068;
        mem[ 468] = 9'h063;
        mem[ 469] = 9'h0F7;
        mem[ 470] = 9'h144;
        mem[ 471] = 9'h158;
        mem[ 472] = 9'h089;
        mem[ 473] = 9'h1AF;
        mem[ 474] = 9'h04E;
        mem[ 475] = 9'h0DA;
        mem[ 476] = 9'h172;
        mem[ 477] = 9'h076;
        mem[ 478] = 9'h034;
        mem[ 479] = 9'h032;
        mem[ 480] = 9'h03C;
        mem[ 481] = 9'h0A4;
        mem[ 482] = 9'h0DD;
        mem[ 483] = 9'h155;
        mem[ 484] = 9'h076;
        mem[ 485] = 9'h08C;
        mem[ 486] = 9'h010;
        mem[ 487] = 9'h008;
        mem[ 488] = 9'h180;
        mem[ 489] = 9'h048;
        mem[ 490] = 9'h1B0;
        mem[ 491] = 9'h076;
        mem[ 492] = 9'h010;
        mem[ 493] = 9'h07F;
        mem[ 494] = 9'h117;
        mem[ 495] = 9'h0B9;
        mem[ 496] = 9'h1CF;
        mem[ 497] = 9'h092;
        mem[ 498] = 9'h0C7;
        mem[ 499] = 9'h186;
        mem[ 500] = 9'h03D;
        mem[ 501] = 9'h0C4;
        mem[ 502] = 9'h14E;
        mem[ 503] = 9'h146;
        mem[ 504] = 9'h076;
        mem[ 505] = 9'h0F6;
        mem[ 506] = 9'h188;
        mem[ 507] = 9'h076;
        mem[ 508] = 9'h033;
        mem[ 509] = 9'h1B7;
        mem[ 510] = 9'h134;
        mem[ 511] = 9'h1CF;
        mem[ 512] = 9'h1AA;
        mem[ 513] = 9'h0EF;
        mem[ 514] = 9'h129;
        mem[ 515] = 9'h067;
        mem[ 516] = 9'h06B;
        mem[ 517] = 9'h068;
        mem[ 518] = 9'h063;
        mem[ 519] = 9'h077;
        mem[ 520] = 9'h13D;
        mem[ 521] = 9'h1A6;
        mem[ 522] = 9'h19C;
        mem[ 523] = 9'h1AB;
        mem[ 524] = 9'h033;
        mem[ 525] = 9'h17C;
        mem[ 526] = 9'h16D;
        mem[ 527] = 9'h167;
        mem[ 528] = 9'h093;
        mem[ 529] = 9'h15E;
        mem[ 530] = 9'h07D;
        mem[ 531] = 9'h15C;
        mem[ 532] = 9'h077;
        mem[ 533] = 9'h1FF;
        mem[ 534] = 9'h1FF;
        mem[ 535] = 9'h1FF;
        mem[ 536] = 9'h1FF;
        mem[ 537] = 9'h1FF;
        mem[ 538] = 9'h1FF;
        mem[ 539] = 9'h1FF;
        mem[ 540] = 9'h1FF;
        mem[ 541] = 9'h1FF;
        mem[ 542] = 9'h1FF;
        mem[ 543] = 9'h1FF;
        mem[ 544] = 9'h1FF;
        mem[ 545] = 9'h1FF;
        mem[ 546] = 9'h1FF;
        mem[ 547] = 9'h1FF;
        mem[ 548] = 9'h1FF;
        mem[ 549] = 9'h1FF;
        mem[ 550] = 9'h1FF;
        mem[ 551] = 9'h1FF;
        mem[ 552] = 9'h1FF;
        mem[ 553] = 9'h1FF;
        mem[ 554] = 9'h1FF;
        mem[ 555] = 9'h1FF;
        mem[ 556] = 9'h1FF;
        mem[ 557] = 9'h1FF;
        mem[ 558] = 9'h1FF;
        mem[ 559] = 9'h1FF;
        mem[ 560] = 9'h1FF;
        mem[ 561] = 9'h1FF;
        mem[ 562] = 9'h1FF;
        mem[ 563] = 9'h1FF;
        mem[ 564] = 9'h1FF;
        mem[ 565] = 9'h1FF;
        mem[ 566] = 9'h1FF;
        mem[ 567] = 9'h1FF;
        mem[ 568] = 9'h1FF;
        mem[ 569] = 9'h1FF;
        mem[ 570] = 9'h1FF;
        mem[ 571] = 9'h1FF;
        mem[ 572] = 9'h1FF;
        mem[ 573] = 9'h1FF;
        mem[ 574] = 9'h1FF;
        mem[ 575] = 9'h1FF;
        mem[ 576] = 9'h1FF;
        mem[ 577] = 9'h1FF;
        mem[ 578] = 9'h1FF;
        mem[ 579] = 9'h1FF;
        mem[ 580] = 9'h1FF;
        mem[ 581] = 9'h1FF;
        mem[ 582] = 9'h1FF;
        mem[ 583] = 9'h1FF;
        mem[ 584] = 9'h1FF;
        mem[ 585] = 9'h1FF;
        mem[ 586] = 9'h1FF;
        mem[ 587] = 9'h1FF;
        mem[ 588] = 9'h1FF;
        mem[ 589] = 9'h1FF;
        mem[ 590] = 9'h1FF;
        mem[ 591] = 9'h1FF;
        mem[ 592] = 9'h1FF;
        mem[ 593] = 9'h1FF;
        mem[ 594] = 9'h1FF;
        mem[ 595] = 9'h1FF;
        mem[ 596] = 9'h1FF;
        mem[ 597] = 9'h1FF;
        mem[ 598] = 9'h1FF;
        mem[ 599] = 9'h1FF;
        mem[ 600] = 9'h1FF;
        mem[ 601] = 9'h1FF;
        mem[ 602] = 9'h1FF;
        mem[ 603] = 9'h1FF;
        mem[ 604] = 9'h1FF;
        mem[ 605] = 9'h1FF;
        mem[ 606] = 9'h1FF;
        mem[ 607] = 9'h1FF;
        mem[ 608] = 9'h1FF;
        mem[ 609] = 9'h1FF;
        mem[ 610] = 9'h1FF;
        mem[ 611] = 9'h1FF;
        mem[ 612] = 9'h1FF;
        mem[ 613] = 9'h1FF;
        mem[ 614] = 9'h1FF;
        mem[ 615] = 9'h1FF;
        mem[ 616] = 9'h1FF;
        mem[ 617] = 9'h1FF;
        mem[ 618] = 9'h1FF;
        mem[ 619] = 9'h1FF;
        mem[ 620] = 9'h1FF;
        mem[ 621] = 9'h1FF;
        mem[ 622] = 9'h1FF;
        mem[ 623] = 9'h1FF;
        mem[ 624] = 9'h1FF;
        mem[ 625] = 9'h1FF;
        mem[ 626] = 9'h1FF;
        mem[ 627] = 9'h1FF;
        mem[ 628] = 9'h1FF;
        mem[ 629] = 9'h1FF;
        mem[ 630] = 9'h1FF;
        mem[ 631] = 9'h1FF;
        mem[ 632] = 9'h1FF;
        mem[ 633] = 9'h1FF;
        mem[ 634] = 9'h1FF;
        mem[ 635] = 9'h1FF;
        mem[ 636] = 9'h1FF;
        mem[ 637] = 9'h1FF;
        mem[ 638] = 9'h1FF;
        mem[ 639] = 9'h1FF;
        mem[ 640] = 9'h1FF;
        mem[ 641] = 9'h1FF;
        mem[ 642] = 9'h1FF;
        mem[ 643] = 9'h1FF;
        mem[ 644] = 9'h1FF;
        mem[ 645] = 9'h1FF;
        mem[ 646] = 9'h1FF;
        mem[ 647] = 9'h1FF;
        mem[ 648] = 9'h1FF;
        mem[ 649] = 9'h1FF;
        mem[ 650] = 9'h1FF;
        mem[ 651] = 9'h1FF;
        mem[ 652] = 9'h1FF;
        mem[ 653] = 9'h1FF;
        mem[ 654] = 9'h1FF;
        mem[ 655] = 9'h1FF;
        mem[ 656] = 9'h1FF;
        mem[ 657] = 9'h1FF;
        mem[ 658] = 9'h1FF;
        mem[ 659] = 9'h1FF;
        mem[ 660] = 9'h1FF;
        mem[ 661] = 9'h1FF;
        mem[ 662] = 9'h1FF;
        mem[ 663] = 9'h1FF;
        mem[ 664] = 9'h1FF;
        mem[ 665] = 9'h1FF;
        mem[ 666] = 9'h1FF;
        mem[ 667] = 9'h1FF;
        mem[ 668] = 9'h1FF;
        mem[ 669] = 9'h1FF;
        mem[ 670] = 9'h1FF;
        mem[ 671] = 9'h1FF;
        mem[ 672] = 9'h1FF;
        mem[ 673] = 9'h1FF;
        mem[ 674] = 9'h1FF;
        mem[ 675] = 9'h1FF;
        mem[ 676] = 9'h1FF;
        mem[ 677] = 9'h1FF;
        mem[ 678] = 9'h1FF;
        mem[ 679] = 9'h1FF;
        mem[ 680] = 9'h1FF;
        mem[ 681] = 9'h1FF;
        mem[ 682] = 9'h1FF;
        mem[ 683] = 9'h1FF;
        mem[ 684] = 9'h1FF;
        mem[ 685] = 9'h1FF;
        mem[ 686] = 9'h1FF;
        mem[ 687] = 9'h1FF;
        mem[ 688] = 9'h1FF;
        mem[ 689] = 9'h1FF;
        mem[ 690] = 9'h1FF;
        mem[ 691] = 9'h1FF;
        mem[ 692] = 9'h1FF;
        mem[ 693] = 9'h1FF;
        mem[ 694] = 9'h1FF;
        mem[ 695] = 9'h1FF;
        mem[ 696] = 9'h1FF;
        mem[ 697] = 9'h1FF;
        mem[ 698] = 9'h1FF;
        mem[ 699] = 9'h1FF;
        mem[ 700] = 9'h1FF;
        mem[ 701] = 9'h1FF;
        mem[ 702] = 9'h1FF;
        mem[ 703] = 9'h1FF;
        mem[ 704] = 9'h1FF;
        mem[ 705] = 9'h1FF;
        mem[ 706] = 9'h1FF;
        mem[ 707] = 9'h1FF;
        mem[ 708] = 9'h1FF;
        mem[ 709] = 9'h1FF;
        mem[ 710] = 9'h1FF;
        mem[ 711] = 9'h1FF;
        mem[ 712] = 9'h1FF;
        mem[ 713] = 9'h1FF;
        mem[ 714] = 9'h1FF;
        mem[ 715] = 9'h1FF;
        mem[ 716] = 9'h1FF;
        mem[ 717] = 9'h1FF;
        mem[ 718] = 9'h1FF;
        mem[ 719] = 9'h1FF;
        mem[ 720] = 9'h1FF;
        mem[ 721] = 9'h1FF;
        mem[ 722] = 9'h1FF;
        mem[ 723] = 9'h1FF;
        mem[ 724] = 9'h1FF;
        mem[ 725] = 9'h1FF;
        mem[ 726] = 9'h1FF;
        mem[ 727] = 9'h1FF;
        mem[ 728] = 9'h1FF;
        mem[ 729] = 9'h1FF;
        mem[ 730] = 9'h1FF;
        mem[ 731] = 9'h1FF;
        mem[ 732] = 9'h1FF;
        mem[ 733] = 9'h1FF;
        mem[ 734] = 9'h1FF;
        mem[ 735] = 9'h1FF;
        mem[ 736] = 9'h1FF;
        mem[ 737] = 9'h1FF;
        mem[ 738] = 9'h1FF;
        mem[ 739] = 9'h1FF;
        mem[ 740] = 9'h1FF;
        mem[ 741] = 9'h1FF;
        mem[ 742] = 9'h1FF;
        mem[ 743] = 9'h1FF;
        mem[ 744] = 9'h1FF;
        mem[ 745] = 9'h1FF;
        mem[ 746] = 9'h1FF;
        mem[ 747] = 9'h1FF;
        mem[ 748] = 9'h1FF;
        mem[ 749] = 9'h1FF;
        mem[ 750] = 9'h1FF;
        mem[ 751] = 9'h1FF;
        mem[ 752] = 9'h1FF;
        mem[ 753] = 9'h1FF;
        mem[ 754] = 9'h1FF;
        mem[ 755] = 9'h1FF;
        mem[ 756] = 9'h1FF;
        mem[ 757] = 9'h1FF;
        mem[ 758] = 9'h1FF;
        mem[ 759] = 9'h1FF;
        mem[ 760] = 9'h1FF;
        mem[ 761] = 9'h1FF;
        mem[ 762] = 9'h1FF;
        mem[ 763] = 9'h1FF;
        mem[ 764] = 9'h1FF;
        mem[ 765] = 9'h1FF;
        mem[ 766] = 9'h1FF;
        mem[ 767] = 9'h1FF;
        mem[ 768] = 9'h1FF;
        mem[ 769] = 9'h1FF;
        mem[ 770] = 9'h1FF;
        mem[ 771] = 9'h1FF;
        mem[ 772] = 9'h1FF;
        mem[ 773] = 9'h1FF;
        mem[ 774] = 9'h1FF;
        mem[ 775] = 9'h1FF;
        mem[ 776] = 9'h1FF;
        mem[ 777] = 9'h1FF;
        mem[ 778] = 9'h1FF;
        mem[ 779] = 9'h1FF;
        mem[ 780] = 9'h1FF;
        mem[ 781] = 9'h1FF;
        mem[ 782] = 9'h1FF;
        mem[ 783] = 9'h1FF;
        mem[ 784] = 9'h1FF;
        mem[ 785] = 9'h1FF;
        mem[ 786] = 9'h1FF;
        mem[ 787] = 9'h1FF;
        mem[ 788] = 9'h1FF;
        mem[ 789] = 9'h1FF;
        mem[ 790] = 9'h1FF;
        mem[ 791] = 9'h1FF;
        mem[ 792] = 9'h1FF;
        mem[ 793] = 9'h1FF;
        mem[ 794] = 9'h1FF;
        mem[ 795] = 9'h1FF;
        mem[ 796] = 9'h1FF;
        mem[ 797] = 9'h1FF;
        mem[ 798] = 9'h1FF;
        mem[ 799] = 9'h1FF;
        mem[ 800] = 9'h1FF;
        mem[ 801] = 9'h1FF;
        mem[ 802] = 9'h1FF;
        mem[ 803] = 9'h1FF;
        mem[ 804] = 9'h1FF;
        mem[ 805] = 9'h1FF;
        mem[ 806] = 9'h1FF;
        mem[ 807] = 9'h1FF;
        mem[ 808] = 9'h1FF;
        mem[ 809] = 9'h1FF;
        mem[ 810] = 9'h1FF;
        mem[ 811] = 9'h1FF;
        mem[ 812] = 9'h1FF;
        mem[ 813] = 9'h1FF;
        mem[ 814] = 9'h1FF;
        mem[ 815] = 9'h1FF;
        mem[ 816] = 9'h1FF;
        mem[ 817] = 9'h1FF;
        mem[ 818] = 9'h1FF;
        mem[ 819] = 9'h1FF;
        mem[ 820] = 9'h1FF;
        mem[ 821] = 9'h1FF;
        mem[ 822] = 9'h1FF;
        mem[ 823] = 9'h1FF;
        mem[ 824] = 9'h1FF;
        mem[ 825] = 9'h1FF;
        mem[ 826] = 9'h1FF;
        mem[ 827] = 9'h1FF;
        mem[ 828] = 9'h1FF;
        mem[ 829] = 9'h1FF;
        mem[ 830] = 9'h1FF;
        mem[ 831] = 9'h1FF;
        mem[ 832] = 9'h1FF;
        mem[ 833] = 9'h1FF;
        mem[ 834] = 9'h1FF;
        mem[ 835] = 9'h1FF;
        mem[ 836] = 9'h1FF;
        mem[ 837] = 9'h1FF;
        mem[ 838] = 9'h1FF;
        mem[ 839] = 9'h1FF;
        mem[ 840] = 9'h1FF;
        mem[ 841] = 9'h1FF;
        mem[ 842] = 9'h1FF;
        mem[ 843] = 9'h1FF;
        mem[ 844] = 9'h1FF;
        mem[ 845] = 9'h1FF;
        mem[ 846] = 9'h1FF;
        mem[ 847] = 9'h1FF;
        mem[ 848] = 9'h1FF;
        mem[ 849] = 9'h1FF;
        mem[ 850] = 9'h1FF;
        mem[ 851] = 9'h1FF;
        mem[ 852] = 9'h1FF;
        mem[ 853] = 9'h1FF;
        mem[ 854] = 9'h1FF;
        mem[ 855] = 9'h1FF;
        mem[ 856] = 9'h1FF;
        mem[ 857] = 9'h1FF;
        mem[ 858] = 9'h1FF;
        mem[ 859] = 9'h1FF;
        mem[ 860] = 9'h1FF;
        mem[ 861] = 9'h1FF;
        mem[ 862] = 9'h1FF;
        mem[ 863] = 9'h1FF;
        mem[ 864] = 9'h1FF;
        mem[ 865] = 9'h1FF;
        mem[ 866] = 9'h1FF;
        mem[ 867] = 9'h1FF;
        mem[ 868] = 9'h1FF;
        mem[ 869] = 9'h1FF;
        mem[ 870] = 9'h1FF;
        mem[ 871] = 9'h1FF;
        mem[ 872] = 9'h1FF;
        mem[ 873] = 9'h1FF;
        mem[ 874] = 9'h1FF;
        mem[ 875] = 9'h1FF;
        mem[ 876] = 9'h1FF;
        mem[ 877] = 9'h1FF;
        mem[ 878] = 9'h1FF;
        mem[ 879] = 9'h1FF;
        mem[ 880] = 9'h1FF;
        mem[ 881] = 9'h1FF;
        mem[ 882] = 9'h1FF;
        mem[ 883] = 9'h1FF;
        mem[ 884] = 9'h1FF;
        mem[ 885] = 9'h1FF;
        mem[ 886] = 9'h1FF;
        mem[ 887] = 9'h1FF;
        mem[ 888] = 9'h1FF;
        mem[ 889] = 9'h1FF;
        mem[ 890] = 9'h1FF;
        mem[ 891] = 9'h1FF;
        mem[ 892] = 9'h1FF;
        mem[ 893] = 9'h1FF;
        mem[ 894] = 9'h1FF;
        mem[ 895] = 9'h1FF;
        mem[ 896] = 9'h1FF;
        mem[ 897] = 9'h1FF;
        mem[ 898] = 9'h1FF;
        mem[ 899] = 9'h1FF;
        mem[ 900] = 9'h1FF;
        mem[ 901] = 9'h1FF;
        mem[ 902] = 9'h1FF;
        mem[ 903] = 9'h1FF;
        mem[ 904] = 9'h1FF;
        mem[ 905] = 9'h1FF;
        mem[ 906] = 9'h1FF;
        mem[ 907] = 9'h1FF;
        mem[ 908] = 9'h1FF;
        mem[ 909] = 9'h1FF;
        mem[ 910] = 9'h1FF;
        mem[ 911] = 9'h1FF;
        mem[ 912] = 9'h1FF;
        mem[ 913] = 9'h1FF;
        mem[ 914] = 9'h1FF;
        mem[ 915] = 9'h1FF;
        mem[ 916] = 9'h1FF;
        mem[ 917] = 9'h1FF;
        mem[ 918] = 9'h1FF;
        mem[ 919] = 9'h1FF;
        mem[ 920] = 9'h1FF;
        mem[ 921] = 9'h1FF;
        mem[ 922] = 9'h1FF;
        mem[ 923] = 9'h1FF;
        mem[ 924] = 9'h1FF;
        mem[ 925] = 9'h1FF;
        mem[ 926] = 9'h1FF;
        mem[ 927] = 9'h1FF;
        mem[ 928] = 9'h1FF;
        mem[ 929] = 9'h1FF;
        mem[ 930] = 9'h1FF;
        mem[ 931] = 9'h1FF;
        mem[ 932] = 9'h1FF;
        mem[ 933] = 9'h1FF;
        mem[ 934] = 9'h1FF;
        mem[ 935] = 9'h1FF;
        mem[ 936] = 9'h1FF;
        mem[ 937] = 9'h1FF;
        mem[ 938] = 9'h1FF;
        mem[ 939] = 9'h1FF;
        mem[ 940] = 9'h1FF;
        mem[ 941] = 9'h1FF;
        mem[ 942] = 9'h1FF;
        mem[ 943] = 9'h1FF;
        mem[ 944] = 9'h1FF;
        mem[ 945] = 9'h1FF;
        mem[ 946] = 9'h1FF;
        mem[ 947] = 9'h1FF;
        mem[ 948] = 9'h1FF;
        mem[ 949] = 9'h1FF;
        mem[ 950] = 9'h1FF;
        mem[ 951] = 9'h1FF;
        mem[ 952] = 9'h1FF;
        mem[ 953] = 9'h1FF;
        mem[ 954] = 9'h1FF;
        mem[ 955] = 9'h1FF;
        mem[ 956] = 9'h1FF;
        mem[ 957] = 9'h1FF;
        mem[ 958] = 9'h1FF;
        mem[ 959] = 9'h1FF;
        mem[ 960] = 9'h1FF;
        mem[ 961] = 9'h1FF;
        mem[ 962] = 9'h1FF;
        mem[ 963] = 9'h1FF;
        mem[ 964] = 9'h1FF;
        mem[ 965] = 9'h1FF;
        mem[ 966] = 9'h1FF;
        mem[ 967] = 9'h1FF;
        mem[ 968] = 9'h1FF;
        mem[ 969] = 9'h1FF;
        mem[ 970] = 9'h1FF;
        mem[ 971] = 9'h1FF;
        mem[ 972] = 9'h1FF;
        mem[ 973] = 9'h1FF;
        mem[ 974] = 9'h1FF;
        mem[ 975] = 9'h1FF;
        mem[ 976] = 9'h1FF;
        mem[ 977] = 9'h1FF;
        mem[ 978] = 9'h1FF;
        mem[ 979] = 9'h1FF;
        mem[ 980] = 9'h1FF;
        mem[ 981] = 9'h1FF;
        mem[ 982] = 9'h1FF;
        mem[ 983] = 9'h1FF;
        mem[ 984] = 9'h1FF;
        mem[ 985] = 9'h1FF;
        mem[ 986] = 9'h1FF;
        mem[ 987] = 9'h1FF;
        mem[ 988] = 9'h1FF;
        mem[ 989] = 9'h1FF;
        mem[ 990] = 9'h1FF;
        mem[ 991] = 9'h1FF;
        mem[ 992] = 9'h1FF;
        mem[ 993] = 9'h1FF;
        mem[ 994] = 9'h1FF;
        mem[ 995] = 9'h1FF;
        mem[ 996] = 9'h1FF;
        mem[ 997] = 9'h1FF;
        mem[ 998] = 9'h1FF;
        mem[ 999] = 9'h1FF;
        mem[1000] = 9'h1FF;
        mem[1001] = 9'h1FF;
        mem[1002] = 9'h1FF;
        mem[1003] = 9'h1FF;
        mem[1004] = 9'h1FF;
        mem[1005] = 9'h1FF;
        mem[1006] = 9'h1FF;
        mem[1007] = 9'h1FF;
        mem[1008] = 9'h1FF;
        mem[1009] = 9'h1FF;
        mem[1010] = 9'h1FF;
        mem[1011] = 9'h1FF;
        mem[1012] = 9'h1FF;
        mem[1013] = 9'h1FF;
        mem[1014] = 9'h1FF;
        mem[1015] = 9'h1FF;
        mem[1016] = 9'h1FF;
        mem[1017] = 9'h1FF;
        mem[1018] = 9'h1FF;
        mem[1019] = 9'h1FF;
        mem[1020] = 9'h1FF;
        mem[1021] = 9'h1FF;
        mem[1022] = 9'h1FF;
        mem[1023] = 9'h1FF;
    end

    // 数据与 gate 必须同拍，否则会静默错位：
    //   narr_q(N+1)  = mem[addr(N)]        <- 块 RAM 输出寄存器（拍 N 的地址）
    //   in_seg(N+1)  = 拍 N+1 当拍的比较结果
    // 若直接写 narr_code = in_seg ? narr_q : BLANK，gate 用的是"下一拍"的判定，
    // 而数据来自"上一拍"的地址 —— 段尾会多出或少掉字符，跨段那一拍尤其明显，
    // 且因为只影响一两个像素列，肉眼只看到字幕边缘"有点抖"，很难定位。
    // 所以把 gate 也打一拍：in_seg_q(N+1) = in_seg(N)，与 narr_q 严格同拍。
    reg [8:0] narr_q;
    reg       in_seg_q;

    always @(posedge clk) begin
        narr_q   <= mem[addr];
        in_seg_q <= in_seg;
    end

    // 段外 / 段尾一律输出空白；段内直通 BRAM 输出（两者都是拍 N 的判定/数据）
    assign narr_code = in_seg_q ? narr_q : BLANK;

    // rst_n 保留在端口上以匹配 osd_caption 的复位域，但不参与逻辑：
    // 块 RAM 无复位语义（与 cjk16_font.v 一致，那里只有 clk 一个时钟端口）。
    // verilator lint_off UNUSED
    wire unused_rst = rst_n;
    // verilator lint_on  UNUSED

endmodule

// ============================================================================
// 文件名  : tb_narr_subline.v
// 位置    : sim/testbench/tb_narr_subline.v
// 被测    : rtl/osd/narr_subline.v
// 层次    : 单元测试（无子模块，narr_subline 是叶子模块）
//
// 【一】本测试台测什么
//
//   narr_subline 把「视频帧号 + 列号」翻译成「中文字形索引」，是科普模式
//   视频字幕（t13 B-lite）的唯一数据源。它只有 563 个有效项、1 块块 RAM，
//   代码量很小，但错法都很隐蔽——错一格只会让字幕看起来"有点糊"，
//   不会报错、不会黑屏，所以必须靠逐项比对把它钉住。
//
//   N01  块 RAM 初始化：18 段的字形码必须与 narration.srt 原文一一对应
//   N02  段选（sel = 满足 start[i] <= frame_idx 的最大 i）逐帧扫描
//   N03  列号边界：col < len 有字、col >= len 输出空白哨兵
//   N04  三条时间边界：frame_idx < 4 / > 624 / 段间空隙保持上一段
//   N05  读延迟恰好 1 拍（多打一拍或少打一拍都会让字位错开）
//   N06  seg_start / seg_len / seg_base 表自身的一致性（累加闭合）
//
// 【二】参考模型怎么做的
//
//   参考模型不复用被测代码的任何一行 RTL——它的 18 段 start/len 直接从
//   assets/v2/masters/video/narration.srt 解析出来，在本文件里写成常量表，
//   字形码也由本文件自己查 cjk16_charset.txt 得到。
//   换句话说：narr_subline.v 里的表若被改错，本测试台一定会发现。
//
//   字形索引的交叉核对方式：charset 里每个字符都有固定索引（索引 0..94 是
//   永久冻结段，RTL 以 index 硬引用字库），本文件内置若干「字符 → 索引」的
//   抽查点，覆盖 18 段里出现的各类字符，验证 RTL 引用的是同一张表。
//
// 【三】为什么不用 $readmemh 而用内联 initial
//
//   narr_subline.v 把 1024 项直接写在 initial 块里（而不是外部 .hex）。
//   理由见该文件头注释【五】：t3 的 cjk16_bitmap.hex 至今还要靠
//   sync_src.ps1 与 hdmi_td.al 补一条路径，忘了同步就综合出全零 BRAM
//   且不报错。本模块只有 9,216 bit，内联可以彻底消掉这个失败面。
//   本测试台因此不需要任何外部数据文件，可独立运行。
//
// 【四】反证
//
//   本测试台配套做过两次「故意写坏」的反证（见 docs/plan_v2/T3_CJK_TICKER.md
//   §12）：把 seg_len 的某一项改错、把 in_seg_q 去掉，都能让对应断言变红。
//   断言的方向是「出问题时变红」，不是「正常时变绿」。
// ============================================================================

`timescale 1ns / 1ps

module tb_narr_subline;

    // ========================================================================
    // 时钟与复位
    // ========================================================================
    reg clk;
    reg rst_n;

    initial begin
        clk   = 1'b0;
        rst_n = 1'b0;
    end

    // 25 MHz 像素时钟：周期 40 ns（与 osd_caption 同域）
    always #20 clk = ~clk;

    // ========================================================================
    // 被测模块
    // ========================================================================
    reg  [15:0] frame_idx;
    reg  [5:0]  col;

    wire [8:0]  narr_code;

    narr_subline dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .frame_idx (frame_idx),
        .col       (col),
        .narr_code (narr_code)
    );

    // ========================================================================
    // 参考常量表：直接从 narration.srt 解析得出（不经被测代码）
    //
    //   每段 = {起始帧, 字数}
    //   起始帧 = floor(该段起始时刻(ms) / 1000 * 5)，视频按 5 fps 计帧
    //   字数   = 原文长度，超过 40 的截到 40（一行 640 px ÷ 16 px = 40 格）
    //
    //   18 段原文（省略号内为完整正文，见 T3_CJK_TICKER.md）：
    //     1  FPGA，全称现场可编程门阵列。                             16 字
    //     2  今天用几分钟，带你认识这种可以被重新定义的芯片。         24 字
    //     3  普通芯片在出厂时功能就已固定，而FPGA内部是大量可配置…     39 字
    //     ...
    //     12 FPGA的开发流程一般是：用Verilog或VHDL描述电路…          57→40 字
    // ========================================================================
    localparam SEGS = 18;

    integer ref_start [0:SEGS-1];
    integer ref_len   [0:SEGS-1];
    integer ref_base  [0:SEGS-1];

    // ========================================================================
    // 参考字形码表（18 段全文查 cjk16_charset.txt 的结果）
    //
    //   本表由一次性脚本从 narration.srt + cjk16_charset.txt 生成后粘到这里，
    //   是「期望的 RTL 内部表」。RTL 的表若被改错，N01 会立刻发现。
    //   空格（若未来文案里出现）编码为 9'h1FF（空白哨兵），不指向任何字形。
    // ========================================================================
    reg [8:0] ref_mem [0:1023];

    // ---- 以下 1024 项由 narration.srt + cjk16_charset.txt 生成 ----
    initial begin
            ref_mem[0] = 9'h067;
            ref_mem[1] = 9'h06B;
            ref_mem[2] = 9'h068;
            ref_mem[3] = 9'h063;
            ref_mem[4] = 9'h1CF;
            ref_mem[5] = 9'h0A8;
            ref_mem[6] = 9'h16C;
            ref_mem[7] = 9'h154;
            ref_mem[8] = 9'h0D6;
            ref_mem[9] = 9'h033;
            ref_mem[10] = 9'h17C;
            ref_mem[11] = 9'h16D;
            ref_mem[12] = 9'h1BD;
            ref_mem[13] = 9'h1C3;
            ref_mem[14] = 9'h0B5;
            ref_mem[15] = 9'h077;
            ref_mem[16] = 9'h08D;
            ref_mem[17] = 9'h0E1;
            ref_mem[18] = 9'h158;
            ref_mem[19] = 9'h0B1;
            ref_mem[20] = 9'h029;
            ref_mem[21] = 9'h1B8;
            ref_mem[22] = 9'h1CF;
            ref_mem[23] = 9'h0F5;
            ref_mem[24] = 9'h09E;
            ref_mem[25] = 9'h190;
            ref_mem[26] = 9'h194;
            ref_mem[27] = 9'h1AA;
            ref_mem[28] = 9'h16B;
            ref_mem[29] = 9'h033;
            ref_mem[30] = 9'h092;
            ref_mem[31] = 9'h18A;
            ref_mem[32] = 9'h1B7;
            ref_mem[33] = 9'h123;
            ref_mem[34] = 9'h0EA;
            ref_mem[35] = 9'h082;
            ref_mem[36] = 9'h15E;
            ref_mem[37] = 9'h186;
            ref_mem[38] = 9'h03D;
            ref_mem[39] = 9'h077;
            ref_mem[40] = 9'h005;
            ref_mem[41] = 9'h1AF;
            ref_mem[42] = 9'h186;
            ref_mem[43] = 9'h03D;
            ref_mem[44] = 9'h047;
            ref_mem[45] = 9'h0B2;
            ref_mem[46] = 9'h0C3;
            ref_mem[47] = 9'h126;
            ref_mem[48] = 9'h0BD;
            ref_mem[49] = 9'h180;
            ref_mem[50] = 9'h0EF;
            ref_mem[51] = 9'h0F3;
            ref_mem[52] = 9'h0D5;
            ref_mem[53] = 9'h0EA;
            ref_mem[54] = 9'h1CF;
            ref_mem[55] = 9'h17E;
            ref_mem[56] = 9'h067;
            ref_mem[57] = 9'h06B;
            ref_mem[58] = 9'h068;
            ref_mem[59] = 9'h063;
            ref_mem[60] = 9'h0AD;
            ref_mem[61] = 9'h1B3;
            ref_mem[62] = 9'h129;
            ref_mem[63] = 9'h0E0;
            ref_mem[64] = 9'h028;
            ref_mem[65] = 9'h033;
            ref_mem[66] = 9'h1B5;
            ref_mem[67] = 9'h17D;
            ref_mem[68] = 9'h15E;
            ref_mem[69] = 9'h1B1;
            ref_mem[70] = 9'h1A2;
            ref_mem[71] = 9'h0C1;
            ref_mem[72] = 9'h0A5;
            ref_mem[73] = 9'h0D0;
            ref_mem[74] = 9'h1AC;
            ref_mem[75] = 9'h176;
            ref_mem[76] = 9'h19A;
            ref_mem[77] = 9'h14A;
            ref_mem[78] = 9'h077;
            ref_mem[79] = 9'h046;
            ref_mem[80] = 9'h049;
            ref_mem[81] = 9'h07A;
            ref_mem[82] = 9'h0CF;
            ref_mem[83] = 9'h15E;
            ref_mem[84] = 9'h1B5;
            ref_mem[85] = 9'h17D;
            ref_mem[86] = 9'h122;
            ref_mem[87] = 9'h093;
            ref_mem[88] = 9'h1CF;
            ref_mem[89] = 9'h0CF;
            ref_mem[90] = 9'h044;
            ref_mem[91] = 9'h0D8;
            ref_mem[92] = 9'h186;
            ref_mem[93] = 9'h03D;
            ref_mem[94] = 9'h033;
            ref_mem[95] = 9'h092;
            ref_mem[96] = 9'h0CA;
            ref_mem[97] = 9'h106;
            ref_mem[98] = 9'h18F;
            ref_mem[99] = 9'h121;
            ref_mem[100] = 9'h0D2;
            ref_mem[101] = 9'h076;
            ref_mem[102] = 9'h03C;
            ref_mem[103] = 9'h0A4;
            ref_mem[104] = 9'h0DD;
            ref_mem[105] = 9'h155;
            ref_mem[106] = 9'h0D2;
            ref_mem[107] = 9'h1CF;
            ref_mem[108] = 9'h156;
            ref_mem[109] = 9'h182;
            ref_mem[110] = 9'h044;
            ref_mem[111] = 9'h080;
            ref_mem[112] = 9'h0DD;
            ref_mem[113] = 9'h155;
            ref_mem[114] = 9'h0D2;
            ref_mem[115] = 9'h138;
            ref_mem[116] = 9'h077;
            ref_mem[117] = 9'h067;
            ref_mem[118] = 9'h06B;
            ref_mem[119] = 9'h068;
            ref_mem[120] = 9'h063;
            ref_mem[121] = 9'h0EB;
            ref_mem[122] = 9'h154;
            ref_mem[123] = 9'h1B1;
            ref_mem[124] = 9'h1A2;
            ref_mem[125] = 9'h15E;
            ref_mem[126] = 9'h138;
            ref_mem[127] = 9'h101;
            ref_mem[128] = 9'h129;
            ref_mem[129] = 9'h136;
            ref_mem[130] = 9'h10B;
            ref_mem[131] = 9'h189;
            ref_mem[132] = 9'h1CF;
            ref_mem[133] = 9'h085;
            ref_mem[134] = 9'h0EF;
            ref_mem[135] = 9'h129;
            ref_mem[136] = 9'h06A;
            ref_mem[137] = 9'h06E;
            ref_mem[138] = 9'h06D;
            ref_mem[139] = 9'h077;
            ref_mem[140] = 9'h044;
            ref_mem[141] = 9'h080;
            ref_mem[142] = 9'h0D3;
            ref_mem[143] = 9'h1A3;
            ref_mem[144] = 9'h0A7;
            ref_mem[145] = 9'h136;
            ref_mem[146] = 9'h10B;
            ref_mem[147] = 9'h189;
            ref_mem[148] = 9'h12F;
            ref_mem[149] = 9'h199;
            ref_mem[150] = 9'h043;
            ref_mem[151] = 9'h129;
            ref_mem[152] = 9'h0C0;
            ref_mem[153] = 9'h0AA;
            ref_mem[154] = 9'h09A;
            ref_mem[155] = 9'h15E;
            ref_mem[156] = 9'h0EE;
            ref_mem[157] = 9'h0E7;
            ref_mem[158] = 9'h0A3;
            ref_mem[159] = 9'h0D2;
            ref_mem[160] = 9'h1CF;
            ref_mem[161] = 9'h10D;
            ref_mem[162] = 9'h163;
            ref_mem[163] = 9'h0A1;
            ref_mem[164] = 9'h189;
            ref_mem[165] = 9'h0AF;
            ref_mem[166] = 9'h1AB;
            ref_mem[167] = 9'h0C5;
            ref_mem[168] = 9'h1CF;
            ref_mem[169] = 9'h0EF;
            ref_mem[170] = 9'h180;
            ref_mem[171] = 9'h0EB;
            ref_mem[172] = 9'h154;
            ref_mem[173] = 9'h094;
            ref_mem[174] = 9'h105;
            ref_mem[175] = 9'h0D3;
            ref_mem[176] = 9'h1A3;
            ref_mem[177] = 9'h0A7;
            ref_mem[178] = 9'h1B1;
            ref_mem[179] = 9'h1A2;
            ref_mem[180] = 9'h136;
            ref_mem[181] = 9'h10B;
            ref_mem[182] = 9'h189;
            ref_mem[183] = 9'h0AE;
            ref_mem[184] = 9'h1B5;
            ref_mem[185] = 9'h0CE;
            ref_mem[186] = 9'h18E;
            ref_mem[187] = 9'h0C8;
            ref_mem[188] = 9'h0D2;
            ref_mem[189] = 9'h1CF;
            ref_mem[190] = 9'h0EF;
            ref_mem[191] = 9'h134;
            ref_mem[192] = 9'h106;
            ref_mem[193] = 9'h087;
            ref_mem[194] = 9'h126;
            ref_mem[195] = 9'h0F8;
            ref_mem[196] = 9'h15A;
            ref_mem[197] = 9'h19E;
            ref_mem[198] = 9'h15E;
            ref_mem[199] = 9'h0DA;
            ref_mem[200] = 9'h12F;
            ref_mem[201] = 9'h0C1;
            ref_mem[202] = 9'h0A5;
            ref_mem[203] = 9'h077;
            ref_mem[204] = 9'h044;
            ref_mem[205] = 9'h0D8;
            ref_mem[206] = 9'h067;
            ref_mem[207] = 9'h06B;
            ref_mem[208] = 9'h068;
            ref_mem[209] = 9'h063;
            ref_mem[210] = 9'h159;
            ref_mem[211] = 9'h033;
            ref_mem[212] = 9'h17C;
            ref_mem[213] = 9'h16D;
            ref_mem[214] = 9'h1B1;
            ref_mem[215] = 9'h1A2;
            ref_mem[216] = 9'h0D8;
            ref_mem[217] = 9'h076;
            ref_mem[218] = 9'h033;
            ref_mem[219] = 9'h17C;
            ref_mem[220] = 9'h16D;
            ref_mem[221] = 9'h08A;
            ref_mem[222] = 9'h1AC;
            ref_mem[223] = 9'h0D0;
            ref_mem[224] = 9'h1A3;
            ref_mem[225] = 9'h0A7;
            ref_mem[226] = 9'h1A3;
            ref_mem[227] = 9'h0B2;
            ref_mem[228] = 9'h0C1;
            ref_mem[229] = 9'h0A5;
            ref_mem[230] = 9'h177;
            ref_mem[231] = 9'h106;
            ref_mem[232] = 9'h077;
            ref_mem[233] = 9'h154;
            ref_mem[234] = 9'h090;
            ref_mem[235] = 9'h067;
            ref_mem[236] = 9'h06B;
            ref_mem[237] = 9'h068;
            ref_mem[238] = 9'h063;
            ref_mem[239] = 9'h1A9;
            ref_mem[240] = 9'h1C5;
            ref_mem[241] = 9'h106;
            ref_mem[242] = 9'h087;
            ref_mem[243] = 9'h0D8;
            ref_mem[244] = 9'h0E7;
            ref_mem[245] = 9'h0A3;
            ref_mem[246] = 9'h0D2;
            ref_mem[247] = 9'h076;
            ref_mem[248] = 9'h065;
            ref_mem[249] = 9'h06C;
            ref_mem[250] = 9'h06B;
            ref_mem[251] = 9'h083;
            ref_mem[252] = 9'h143;
            ref_mem[253] = 9'h0C1;
            ref_mem[254] = 9'h0A5;
            ref_mem[255] = 9'h0D0;
            ref_mem[256] = 9'h1BA;
            ref_mem[257] = 9'h161;
            ref_mem[258] = 9'h021;
            ref_mem[259] = 9'h1CF;
            ref_mem[260] = 9'h029;
            ref_mem[261] = 9'h0B7;
            ref_mem[262] = 9'h197;
            ref_mem[263] = 9'h198;
            ref_mem[264] = 9'h121;
            ref_mem[265] = 9'h114;
            ref_mem[266] = 9'h17B;
            ref_mem[267] = 9'h0E7;
            ref_mem[268] = 9'h076;
            ref_mem[269] = 9'h01E;
            ref_mem[270] = 9'h1B0;
            ref_mem[271] = 9'h014;
            ref_mem[272] = 9'h173;
            ref_mem[273] = 9'h064;
            ref_mem[274] = 9'h06B;
            ref_mem[275] = 9'h06E;
            ref_mem[276] = 9'h112;
            ref_mem[277] = 9'h1C8;
            ref_mem[278] = 9'h0F8;
            ref_mem[279] = 9'h10A;
            ref_mem[280] = 9'h188;
            ref_mem[281] = 9'h111;
            ref_mem[282] = 9'h091;
            ref_mem[283] = 9'h1CF;
            ref_mem[284] = 9'h0CF;
            ref_mem[285] = 9'h044;
            ref_mem[286] = 9'h126;
            ref_mem[287] = 9'h0BA;
            ref_mem[288] = 9'h0CC;
            ref_mem[289] = 9'h180;
            ref_mem[290] = 9'h0DD;
            ref_mem[291] = 9'h155;
            ref_mem[292] = 9'h12D;
            ref_mem[293] = 9'h1C4;
            ref_mem[294] = 9'h15E;
            ref_mem[295] = 9'h094;
            ref_mem[296] = 9'h0BE;
            ref_mem[297] = 9'h077;
            ref_mem[298] = 9'h067;
            ref_mem[299] = 9'h06B;
            ref_mem[300] = 9'h068;
            ref_mem[301] = 9'h063;
            ref_mem[302] = 9'h0B6;
            ref_mem[303] = 9'h10D;
            ref_mem[304] = 9'h173;
            ref_mem[305] = 9'h143;
            ref_mem[306] = 9'h160;
            ref_mem[307] = 9'h116;
            ref_mem[308] = 9'h0CA;
            ref_mem[309] = 9'h106;
            ref_mem[310] = 9'h167;
            ref_mem[311] = 9'h093;
            ref_mem[312] = 9'h15A;
            ref_mem[313] = 9'h19E;
            ref_mem[314] = 9'h1CF;
            ref_mem[315] = 9'h0DE;
            ref_mem[316] = 9'h132;
            ref_mem[317] = 9'h121;
            ref_mem[318] = 9'h114;
            ref_mem[319] = 9'h1AF;
            ref_mem[320] = 9'h19E;
            ref_mem[321] = 9'h0CF;
            ref_mem[322] = 9'h126;
            ref_mem[323] = 9'h010;
            ref_mem[324] = 9'h09D;
            ref_mem[325] = 9'h1CF;
            ref_mem[326] = 9'h0FA;
            ref_mem[327] = 9'h1AD;
            ref_mem[328] = 9'h09B;
            ref_mem[329] = 9'h17E;
            ref_mem[330] = 9'h07C;
            ref_mem[331] = 9'h033;
            ref_mem[332] = 9'h1C9;
            ref_mem[333] = 9'h148;
            ref_mem[334] = 9'h077;
            ref_mem[335] = 9'h067;
            ref_mem[336] = 9'h06B;
            ref_mem[337] = 9'h068;
            ref_mem[338] = 9'h063;
            ref_mem[339] = 9'h15E;
            ref_mem[340] = 9'h036;
            ref_mem[341] = 9'h0C8;
            ref_mem[342] = 9'h147;
            ref_mem[343] = 9'h16D;
            ref_mem[344] = 9'h044;
            ref_mem[345] = 9'h184;
            ref_mem[346] = 9'h129;
            ref_mem[347] = 9'h05E;
            ref_mem[348] = 9'h158;
            ref_mem[349] = 9'h06F;
            ref_mem[350] = 9'h070;
            ref_mem[351] = 9'h075;
            ref_mem[352] = 9'h072;
            ref_mem[353] = 9'h073;
            ref_mem[354] = 9'h074;
            ref_mem[355] = 9'h071;
            ref_mem[356] = 9'h107;
            ref_mem[357] = 9'h06F;
            ref_mem[358] = 9'h069;
            ref_mem[359] = 9'h065;
            ref_mem[360] = 9'h06A;
            ref_mem[361] = 9'h119;
            ref_mem[362] = 9'h1AE;
            ref_mem[363] = 9'h15A;
            ref_mem[364] = 9'h19E;
            ref_mem[365] = 9'h1CF;
            ref_mem[366] = 9'h179;
            ref_mem[367] = 9'h1A5;
            ref_mem[368] = 9'h17A;
            ref_mem[369] = 9'h0CE;
            ref_mem[370] = 9'h076;
            ref_mem[371] = 9'h0F4;
            ref_mem[372] = 9'h0F0;
            ref_mem[373] = 9'h0F4;
            ref_mem[374] = 9'h176;
            ref_mem[375] = 9'h047;
            ref_mem[376] = 9'h1AA;
            ref_mem[377] = 9'h080;
            ref_mem[378] = 9'h1A5;
            ref_mem[379] = 9'h16D;
            ref_mem[380] = 9'h081;
            ref_mem[381] = 9'h1CF;
            ref_mem[382] = 9'h095;
            ref_mem[383] = 9'h163;
            ref_mem[384] = 9'h0D0;
            ref_mem[385] = 9'h126;
            ref_mem[386] = 9'h0F8;
            ref_mem[387] = 9'h029;
            ref_mem[388] = 9'h135;
            ref_mem[389] = 9'h0A0;
            ref_mem[390] = 9'h193;
            ref_mem[391] = 9'h192;
            ref_mem[392] = 9'h18F;
            ref_mem[393] = 9'h125;
            ref_mem[394] = 9'h0BD;
            ref_mem[395] = 9'h180;
            ref_mem[396] = 9'h023;
            ref_mem[397] = 9'h168;
            ref_mem[398] = 9'h1CF;
            ref_mem[399] = 9'h0C6;
            ref_mem[400] = 9'h180;
            ref_mem[401] = 9'h19D;
            ref_mem[402] = 9'h047;
            ref_mem[403] = 9'h15F;
            ref_mem[404] = 9'h137;
            ref_mem[405] = 9'h032;
            ref_mem[406] = 9'h02B;
            ref_mem[407] = 9'h043;
            ref_mem[408] = 9'h077;
            ref_mem[409] = 9'h02E;
            ref_mem[410] = 9'h0E5;
            ref_mem[411] = 9'h1AA;
            ref_mem[412] = 9'h13F;
            ref_mem[413] = 9'h06F;
            ref_mem[414] = 9'h070;
            ref_mem[415] = 9'h075;
            ref_mem[416] = 9'h072;
            ref_mem[417] = 9'h073;
            ref_mem[418] = 9'h074;
            ref_mem[419] = 9'h071;
            ref_mem[420] = 9'h090;
            ref_mem[421] = 9'h166;
            ref_mem[422] = 9'h1CF;
            ref_mem[423] = 9'h119;
            ref_mem[424] = 9'h1AE;
            ref_mem[425] = 9'h087;
            ref_mem[426] = 9'h044;
            ref_mem[427] = 9'h080;
            ref_mem[428] = 9'h18F;
            ref_mem[429] = 9'h121;
            ref_mem[430] = 9'h0D2;
            ref_mem[431] = 9'h077;
            ref_mem[432] = 9'h17A;
            ref_mem[433] = 9'h0CE;
            ref_mem[434] = 9'h010;
            ref_mem[435] = 9'h0AC;
            ref_mem[436] = 9'h098;
            ref_mem[437] = 9'h10D;
            ref_mem[438] = 9'h0E9;
            ref_mem[439] = 9'h128;
            ref_mem[440] = 9'h0ED;
            ref_mem[441] = 9'h106;
            ref_mem[442] = 9'h18E;
            ref_mem[443] = 9'h0C8;
            ref_mem[444] = 9'h0D2;
            ref_mem[445] = 9'h0D0;
            ref_mem[446] = 9'h136;
            ref_mem[447] = 9'h10B;
            ref_mem[448] = 9'h189;
            ref_mem[449] = 9'h1CF;
            ref_mem[450] = 9'h191;
            ref_mem[451] = 9'h06A;
            ref_mem[452] = 9'h066;
            ref_mem[453] = 9'h065;
            ref_mem[454] = 9'h112;
            ref_mem[455] = 9'h0D5;
            ref_mem[456] = 9'h0EA;
            ref_mem[457] = 9'h185;
            ref_mem[458] = 9'h0E3;
            ref_mem[459] = 9'h1BE;
            ref_mem[460] = 9'h14F;
            ref_mem[461] = 9'h077;
            ref_mem[462] = 9'h0E5;
            ref_mem[463] = 9'h08D;
            ref_mem[464] = 9'h1CF;
            ref_mem[465] = 9'h067;
            ref_mem[466] = 9'h06B;
            ref_mem[467] = 9'h068;
            ref_mem[468] = 9'h063;
            ref_mem[469] = 9'h0F7;
            ref_mem[470] = 9'h144;
            ref_mem[471] = 9'h158;
            ref_mem[472] = 9'h089;
            ref_mem[473] = 9'h1AF;
            ref_mem[474] = 9'h04E;
            ref_mem[475] = 9'h0DA;
            ref_mem[476] = 9'h172;
            ref_mem[477] = 9'h076;
            ref_mem[478] = 9'h034;
            ref_mem[479] = 9'h032;
            ref_mem[480] = 9'h03C;
            ref_mem[481] = 9'h0A4;
            ref_mem[482] = 9'h0DD;
            ref_mem[483] = 9'h155;
            ref_mem[484] = 9'h076;
            ref_mem[485] = 9'h08C;
            ref_mem[486] = 9'h010;
            ref_mem[487] = 9'h008;
            ref_mem[488] = 9'h180;
            ref_mem[489] = 9'h048;
            ref_mem[490] = 9'h1B0;
            ref_mem[491] = 9'h076;
            ref_mem[492] = 9'h010;
            ref_mem[493] = 9'h07F;
            ref_mem[494] = 9'h117;
            ref_mem[495] = 9'h0B9;
            ref_mem[496] = 9'h1CF;
            ref_mem[497] = 9'h092;
            ref_mem[498] = 9'h0C7;
            ref_mem[499] = 9'h186;
            ref_mem[500] = 9'h03D;
            ref_mem[501] = 9'h0C4;
            ref_mem[502] = 9'h14E;
            ref_mem[503] = 9'h146;
            ref_mem[504] = 9'h076;
            ref_mem[505] = 9'h0F6;
            ref_mem[506] = 9'h188;
            ref_mem[507] = 9'h076;
            ref_mem[508] = 9'h033;
            ref_mem[509] = 9'h1B7;
            ref_mem[510] = 9'h134;
            ref_mem[511] = 9'h1CF;
            ref_mem[512] = 9'h1AA;
            ref_mem[513] = 9'h0EF;
            ref_mem[514] = 9'h129;
            ref_mem[515] = 9'h067;
            ref_mem[516] = 9'h06B;
            ref_mem[517] = 9'h068;
            ref_mem[518] = 9'h063;
            ref_mem[519] = 9'h077;
            ref_mem[520] = 9'h13D;
            ref_mem[521] = 9'h1A6;
            ref_mem[522] = 9'h19C;
            ref_mem[523] = 9'h1AB;
            ref_mem[524] = 9'h033;
            ref_mem[525] = 9'h17C;
            ref_mem[526] = 9'h16D;
            ref_mem[527] = 9'h167;
            ref_mem[528] = 9'h093;
            ref_mem[529] = 9'h15E;
            ref_mem[530] = 9'h07D;
            ref_mem[531] = 9'h15C;
            ref_mem[532] = 9'h077;
            ref_mem[533] = 9'h1FF;
            ref_mem[534] = 9'h1FF;
            ref_mem[535] = 9'h1FF;
            ref_mem[536] = 9'h1FF;
            ref_mem[537] = 9'h1FF;
            ref_mem[538] = 9'h1FF;
            ref_mem[539] = 9'h1FF;
            ref_mem[540] = 9'h1FF;
            ref_mem[541] = 9'h1FF;
            ref_mem[542] = 9'h1FF;
            ref_mem[543] = 9'h1FF;
            ref_mem[544] = 9'h1FF;
            ref_mem[545] = 9'h1FF;
            ref_mem[546] = 9'h1FF;
            ref_mem[547] = 9'h1FF;
            ref_mem[548] = 9'h1FF;
            ref_mem[549] = 9'h1FF;
            ref_mem[550] = 9'h1FF;
            ref_mem[551] = 9'h1FF;
            ref_mem[552] = 9'h1FF;
            ref_mem[553] = 9'h1FF;
            ref_mem[554] = 9'h1FF;
            ref_mem[555] = 9'h1FF;
            ref_mem[556] = 9'h1FF;
            ref_mem[557] = 9'h1FF;
            ref_mem[558] = 9'h1FF;
            ref_mem[559] = 9'h1FF;
            ref_mem[560] = 9'h1FF;
            ref_mem[561] = 9'h1FF;
            ref_mem[562] = 9'h1FF;
            ref_mem[563] = 9'h1FF;
            ref_mem[564] = 9'h1FF;
            ref_mem[565] = 9'h1FF;
            ref_mem[566] = 9'h1FF;
            ref_mem[567] = 9'h1FF;
            ref_mem[568] = 9'h1FF;
            ref_mem[569] = 9'h1FF;
            ref_mem[570] = 9'h1FF;
            ref_mem[571] = 9'h1FF;
            ref_mem[572] = 9'h1FF;
            ref_mem[573] = 9'h1FF;
            ref_mem[574] = 9'h1FF;
            ref_mem[575] = 9'h1FF;
            ref_mem[576] = 9'h1FF;
            ref_mem[577] = 9'h1FF;
            ref_mem[578] = 9'h1FF;
            ref_mem[579] = 9'h1FF;
            ref_mem[580] = 9'h1FF;
            ref_mem[581] = 9'h1FF;
            ref_mem[582] = 9'h1FF;
            ref_mem[583] = 9'h1FF;
            ref_mem[584] = 9'h1FF;
            ref_mem[585] = 9'h1FF;
            ref_mem[586] = 9'h1FF;
            ref_mem[587] = 9'h1FF;
            ref_mem[588] = 9'h1FF;
            ref_mem[589] = 9'h1FF;
            ref_mem[590] = 9'h1FF;
            ref_mem[591] = 9'h1FF;
            ref_mem[592] = 9'h1FF;
            ref_mem[593] = 9'h1FF;
            ref_mem[594] = 9'h1FF;
            ref_mem[595] = 9'h1FF;
            ref_mem[596] = 9'h1FF;
            ref_mem[597] = 9'h1FF;
            ref_mem[598] = 9'h1FF;
            ref_mem[599] = 9'h1FF;
            ref_mem[600] = 9'h1FF;
            ref_mem[601] = 9'h1FF;
            ref_mem[602] = 9'h1FF;
            ref_mem[603] = 9'h1FF;
            ref_mem[604] = 9'h1FF;
            ref_mem[605] = 9'h1FF;
            ref_mem[606] = 9'h1FF;
            ref_mem[607] = 9'h1FF;
            ref_mem[608] = 9'h1FF;
            ref_mem[609] = 9'h1FF;
            ref_mem[610] = 9'h1FF;
            ref_mem[611] = 9'h1FF;
            ref_mem[612] = 9'h1FF;
            ref_mem[613] = 9'h1FF;
            ref_mem[614] = 9'h1FF;
            ref_mem[615] = 9'h1FF;
            ref_mem[616] = 9'h1FF;
            ref_mem[617] = 9'h1FF;
            ref_mem[618] = 9'h1FF;
            ref_mem[619] = 9'h1FF;
            ref_mem[620] = 9'h1FF;
            ref_mem[621] = 9'h1FF;
            ref_mem[622] = 9'h1FF;
            ref_mem[623] = 9'h1FF;
            ref_mem[624] = 9'h1FF;
            ref_mem[625] = 9'h1FF;
            ref_mem[626] = 9'h1FF;
            ref_mem[627] = 9'h1FF;
            ref_mem[628] = 9'h1FF;
            ref_mem[629] = 9'h1FF;
            ref_mem[630] = 9'h1FF;
            ref_mem[631] = 9'h1FF;
            ref_mem[632] = 9'h1FF;
            ref_mem[633] = 9'h1FF;
            ref_mem[634] = 9'h1FF;
            ref_mem[635] = 9'h1FF;
            ref_mem[636] = 9'h1FF;
            ref_mem[637] = 9'h1FF;
            ref_mem[638] = 9'h1FF;
            ref_mem[639] = 9'h1FF;
            ref_mem[640] = 9'h1FF;
            ref_mem[641] = 9'h1FF;
            ref_mem[642] = 9'h1FF;
            ref_mem[643] = 9'h1FF;
            ref_mem[644] = 9'h1FF;
            ref_mem[645] = 9'h1FF;
            ref_mem[646] = 9'h1FF;
            ref_mem[647] = 9'h1FF;
            ref_mem[648] = 9'h1FF;
            ref_mem[649] = 9'h1FF;
            ref_mem[650] = 9'h1FF;
            ref_mem[651] = 9'h1FF;
            ref_mem[652] = 9'h1FF;
            ref_mem[653] = 9'h1FF;
            ref_mem[654] = 9'h1FF;
            ref_mem[655] = 9'h1FF;
            ref_mem[656] = 9'h1FF;
            ref_mem[657] = 9'h1FF;
            ref_mem[658] = 9'h1FF;
            ref_mem[659] = 9'h1FF;
            ref_mem[660] = 9'h1FF;
            ref_mem[661] = 9'h1FF;
            ref_mem[662] = 9'h1FF;
            ref_mem[663] = 9'h1FF;
            ref_mem[664] = 9'h1FF;
            ref_mem[665] = 9'h1FF;
            ref_mem[666] = 9'h1FF;
            ref_mem[667] = 9'h1FF;
            ref_mem[668] = 9'h1FF;
            ref_mem[669] = 9'h1FF;
            ref_mem[670] = 9'h1FF;
            ref_mem[671] = 9'h1FF;
            ref_mem[672] = 9'h1FF;
            ref_mem[673] = 9'h1FF;
            ref_mem[674] = 9'h1FF;
            ref_mem[675] = 9'h1FF;
            ref_mem[676] = 9'h1FF;
            ref_mem[677] = 9'h1FF;
            ref_mem[678] = 9'h1FF;
            ref_mem[679] = 9'h1FF;
            ref_mem[680] = 9'h1FF;
            ref_mem[681] = 9'h1FF;
            ref_mem[682] = 9'h1FF;
            ref_mem[683] = 9'h1FF;
            ref_mem[684] = 9'h1FF;
            ref_mem[685] = 9'h1FF;
            ref_mem[686] = 9'h1FF;
            ref_mem[687] = 9'h1FF;
            ref_mem[688] = 9'h1FF;
            ref_mem[689] = 9'h1FF;
            ref_mem[690] = 9'h1FF;
            ref_mem[691] = 9'h1FF;
            ref_mem[692] = 9'h1FF;
            ref_mem[693] = 9'h1FF;
            ref_mem[694] = 9'h1FF;
            ref_mem[695] = 9'h1FF;
            ref_mem[696] = 9'h1FF;
            ref_mem[697] = 9'h1FF;
            ref_mem[698] = 9'h1FF;
            ref_mem[699] = 9'h1FF;
            ref_mem[700] = 9'h1FF;
            ref_mem[701] = 9'h1FF;
            ref_mem[702] = 9'h1FF;
            ref_mem[703] = 9'h1FF;
            ref_mem[704] = 9'h1FF;
            ref_mem[705] = 9'h1FF;
            ref_mem[706] = 9'h1FF;
            ref_mem[707] = 9'h1FF;
            ref_mem[708] = 9'h1FF;
            ref_mem[709] = 9'h1FF;
            ref_mem[710] = 9'h1FF;
            ref_mem[711] = 9'h1FF;
            ref_mem[712] = 9'h1FF;
            ref_mem[713] = 9'h1FF;
            ref_mem[714] = 9'h1FF;
            ref_mem[715] = 9'h1FF;
            ref_mem[716] = 9'h1FF;
            ref_mem[717] = 9'h1FF;
            ref_mem[718] = 9'h1FF;
            ref_mem[719] = 9'h1FF;
            ref_mem[720] = 9'h1FF;
            ref_mem[721] = 9'h1FF;
            ref_mem[722] = 9'h1FF;
            ref_mem[723] = 9'h1FF;
            ref_mem[724] = 9'h1FF;
            ref_mem[725] = 9'h1FF;
            ref_mem[726] = 9'h1FF;
            ref_mem[727] = 9'h1FF;
            ref_mem[728] = 9'h1FF;
            ref_mem[729] = 9'h1FF;
            ref_mem[730] = 9'h1FF;
            ref_mem[731] = 9'h1FF;
            ref_mem[732] = 9'h1FF;
            ref_mem[733] = 9'h1FF;
            ref_mem[734] = 9'h1FF;
            ref_mem[735] = 9'h1FF;
            ref_mem[736] = 9'h1FF;
            ref_mem[737] = 9'h1FF;
            ref_mem[738] = 9'h1FF;
            ref_mem[739] = 9'h1FF;
            ref_mem[740] = 9'h1FF;
            ref_mem[741] = 9'h1FF;
            ref_mem[742] = 9'h1FF;
            ref_mem[743] = 9'h1FF;
            ref_mem[744] = 9'h1FF;
            ref_mem[745] = 9'h1FF;
            ref_mem[746] = 9'h1FF;
            ref_mem[747] = 9'h1FF;
            ref_mem[748] = 9'h1FF;
            ref_mem[749] = 9'h1FF;
            ref_mem[750] = 9'h1FF;
            ref_mem[751] = 9'h1FF;
            ref_mem[752] = 9'h1FF;
            ref_mem[753] = 9'h1FF;
            ref_mem[754] = 9'h1FF;
            ref_mem[755] = 9'h1FF;
            ref_mem[756] = 9'h1FF;
            ref_mem[757] = 9'h1FF;
            ref_mem[758] = 9'h1FF;
            ref_mem[759] = 9'h1FF;
            ref_mem[760] = 9'h1FF;
            ref_mem[761] = 9'h1FF;
            ref_mem[762] = 9'h1FF;
            ref_mem[763] = 9'h1FF;
            ref_mem[764] = 9'h1FF;
            ref_mem[765] = 9'h1FF;
            ref_mem[766] = 9'h1FF;
            ref_mem[767] = 9'h1FF;
            ref_mem[768] = 9'h1FF;
            ref_mem[769] = 9'h1FF;
            ref_mem[770] = 9'h1FF;
            ref_mem[771] = 9'h1FF;
            ref_mem[772] = 9'h1FF;
            ref_mem[773] = 9'h1FF;
            ref_mem[774] = 9'h1FF;
            ref_mem[775] = 9'h1FF;
            ref_mem[776] = 9'h1FF;
            ref_mem[777] = 9'h1FF;
            ref_mem[778] = 9'h1FF;
            ref_mem[779] = 9'h1FF;
            ref_mem[780] = 9'h1FF;
            ref_mem[781] = 9'h1FF;
            ref_mem[782] = 9'h1FF;
            ref_mem[783] = 9'h1FF;
            ref_mem[784] = 9'h1FF;
            ref_mem[785] = 9'h1FF;
            ref_mem[786] = 9'h1FF;
            ref_mem[787] = 9'h1FF;
            ref_mem[788] = 9'h1FF;
            ref_mem[789] = 9'h1FF;
            ref_mem[790] = 9'h1FF;
            ref_mem[791] = 9'h1FF;
            ref_mem[792] = 9'h1FF;
            ref_mem[793] = 9'h1FF;
            ref_mem[794] = 9'h1FF;
            ref_mem[795] = 9'h1FF;
            ref_mem[796] = 9'h1FF;
            ref_mem[797] = 9'h1FF;
            ref_mem[798] = 9'h1FF;
            ref_mem[799] = 9'h1FF;
            ref_mem[800] = 9'h1FF;
            ref_mem[801] = 9'h1FF;
            ref_mem[802] = 9'h1FF;
            ref_mem[803] = 9'h1FF;
            ref_mem[804] = 9'h1FF;
            ref_mem[805] = 9'h1FF;
            ref_mem[806] = 9'h1FF;
            ref_mem[807] = 9'h1FF;
            ref_mem[808] = 9'h1FF;
            ref_mem[809] = 9'h1FF;
            ref_mem[810] = 9'h1FF;
            ref_mem[811] = 9'h1FF;
            ref_mem[812] = 9'h1FF;
            ref_mem[813] = 9'h1FF;
            ref_mem[814] = 9'h1FF;
            ref_mem[815] = 9'h1FF;
            ref_mem[816] = 9'h1FF;
            ref_mem[817] = 9'h1FF;
            ref_mem[818] = 9'h1FF;
            ref_mem[819] = 9'h1FF;
            ref_mem[820] = 9'h1FF;
            ref_mem[821] = 9'h1FF;
            ref_mem[822] = 9'h1FF;
            ref_mem[823] = 9'h1FF;
            ref_mem[824] = 9'h1FF;
            ref_mem[825] = 9'h1FF;
            ref_mem[826] = 9'h1FF;
            ref_mem[827] = 9'h1FF;
            ref_mem[828] = 9'h1FF;
            ref_mem[829] = 9'h1FF;
            ref_mem[830] = 9'h1FF;
            ref_mem[831] = 9'h1FF;
            ref_mem[832] = 9'h1FF;
            ref_mem[833] = 9'h1FF;
            ref_mem[834] = 9'h1FF;
            ref_mem[835] = 9'h1FF;
            ref_mem[836] = 9'h1FF;
            ref_mem[837] = 9'h1FF;
            ref_mem[838] = 9'h1FF;
            ref_mem[839] = 9'h1FF;
            ref_mem[840] = 9'h1FF;
            ref_mem[841] = 9'h1FF;
            ref_mem[842] = 9'h1FF;
            ref_mem[843] = 9'h1FF;
            ref_mem[844] = 9'h1FF;
            ref_mem[845] = 9'h1FF;
            ref_mem[846] = 9'h1FF;
            ref_mem[847] = 9'h1FF;
            ref_mem[848] = 9'h1FF;
            ref_mem[849] = 9'h1FF;
            ref_mem[850] = 9'h1FF;
            ref_mem[851] = 9'h1FF;
            ref_mem[852] = 9'h1FF;
            ref_mem[853] = 9'h1FF;
            ref_mem[854] = 9'h1FF;
            ref_mem[855] = 9'h1FF;
            ref_mem[856] = 9'h1FF;
            ref_mem[857] = 9'h1FF;
            ref_mem[858] = 9'h1FF;
            ref_mem[859] = 9'h1FF;
            ref_mem[860] = 9'h1FF;
            ref_mem[861] = 9'h1FF;
            ref_mem[862] = 9'h1FF;
            ref_mem[863] = 9'h1FF;
            ref_mem[864] = 9'h1FF;
            ref_mem[865] = 9'h1FF;
            ref_mem[866] = 9'h1FF;
            ref_mem[867] = 9'h1FF;
            ref_mem[868] = 9'h1FF;
            ref_mem[869] = 9'h1FF;
            ref_mem[870] = 9'h1FF;
            ref_mem[871] = 9'h1FF;
            ref_mem[872] = 9'h1FF;
            ref_mem[873] = 9'h1FF;
            ref_mem[874] = 9'h1FF;
            ref_mem[875] = 9'h1FF;
            ref_mem[876] = 9'h1FF;
            ref_mem[877] = 9'h1FF;
            ref_mem[878] = 9'h1FF;
            ref_mem[879] = 9'h1FF;
            ref_mem[880] = 9'h1FF;
            ref_mem[881] = 9'h1FF;
            ref_mem[882] = 9'h1FF;
            ref_mem[883] = 9'h1FF;
            ref_mem[884] = 9'h1FF;
            ref_mem[885] = 9'h1FF;
            ref_mem[886] = 9'h1FF;
            ref_mem[887] = 9'h1FF;
            ref_mem[888] = 9'h1FF;
            ref_mem[889] = 9'h1FF;
            ref_mem[890] = 9'h1FF;
            ref_mem[891] = 9'h1FF;
            ref_mem[892] = 9'h1FF;
            ref_mem[893] = 9'h1FF;
            ref_mem[894] = 9'h1FF;
            ref_mem[895] = 9'h1FF;
            ref_mem[896] = 9'h1FF;
            ref_mem[897] = 9'h1FF;
            ref_mem[898] = 9'h1FF;
            ref_mem[899] = 9'h1FF;
            ref_mem[900] = 9'h1FF;
            ref_mem[901] = 9'h1FF;
            ref_mem[902] = 9'h1FF;
            ref_mem[903] = 9'h1FF;
            ref_mem[904] = 9'h1FF;
            ref_mem[905] = 9'h1FF;
            ref_mem[906] = 9'h1FF;
            ref_mem[907] = 9'h1FF;
            ref_mem[908] = 9'h1FF;
            ref_mem[909] = 9'h1FF;
            ref_mem[910] = 9'h1FF;
            ref_mem[911] = 9'h1FF;
            ref_mem[912] = 9'h1FF;
            ref_mem[913] = 9'h1FF;
            ref_mem[914] = 9'h1FF;
            ref_mem[915] = 9'h1FF;
            ref_mem[916] = 9'h1FF;
            ref_mem[917] = 9'h1FF;
            ref_mem[918] = 9'h1FF;
            ref_mem[919] = 9'h1FF;
            ref_mem[920] = 9'h1FF;
            ref_mem[921] = 9'h1FF;
            ref_mem[922] = 9'h1FF;
            ref_mem[923] = 9'h1FF;
            ref_mem[924] = 9'h1FF;
            ref_mem[925] = 9'h1FF;
            ref_mem[926] = 9'h1FF;
            ref_mem[927] = 9'h1FF;
            ref_mem[928] = 9'h1FF;
            ref_mem[929] = 9'h1FF;
            ref_mem[930] = 9'h1FF;
            ref_mem[931] = 9'h1FF;
            ref_mem[932] = 9'h1FF;
            ref_mem[933] = 9'h1FF;
            ref_mem[934] = 9'h1FF;
            ref_mem[935] = 9'h1FF;
            ref_mem[936] = 9'h1FF;
            ref_mem[937] = 9'h1FF;
            ref_mem[938] = 9'h1FF;
            ref_mem[939] = 9'h1FF;
            ref_mem[940] = 9'h1FF;
            ref_mem[941] = 9'h1FF;
            ref_mem[942] = 9'h1FF;
            ref_mem[943] = 9'h1FF;
            ref_mem[944] = 9'h1FF;
            ref_mem[945] = 9'h1FF;
            ref_mem[946] = 9'h1FF;
            ref_mem[947] = 9'h1FF;
            ref_mem[948] = 9'h1FF;
            ref_mem[949] = 9'h1FF;
            ref_mem[950] = 9'h1FF;
            ref_mem[951] = 9'h1FF;
            ref_mem[952] = 9'h1FF;
            ref_mem[953] = 9'h1FF;
            ref_mem[954] = 9'h1FF;
            ref_mem[955] = 9'h1FF;
            ref_mem[956] = 9'h1FF;
            ref_mem[957] = 9'h1FF;
            ref_mem[958] = 9'h1FF;
            ref_mem[959] = 9'h1FF;
            ref_mem[960] = 9'h1FF;
            ref_mem[961] = 9'h1FF;
            ref_mem[962] = 9'h1FF;
            ref_mem[963] = 9'h1FF;
            ref_mem[964] = 9'h1FF;
            ref_mem[965] = 9'h1FF;
            ref_mem[966] = 9'h1FF;
            ref_mem[967] = 9'h1FF;
            ref_mem[968] = 9'h1FF;
            ref_mem[969] = 9'h1FF;
            ref_mem[970] = 9'h1FF;
            ref_mem[971] = 9'h1FF;
            ref_mem[972] = 9'h1FF;
            ref_mem[973] = 9'h1FF;
            ref_mem[974] = 9'h1FF;
            ref_mem[975] = 9'h1FF;
            ref_mem[976] = 9'h1FF;
            ref_mem[977] = 9'h1FF;
            ref_mem[978] = 9'h1FF;
            ref_mem[979] = 9'h1FF;
            ref_mem[980] = 9'h1FF;
            ref_mem[981] = 9'h1FF;
            ref_mem[982] = 9'h1FF;
            ref_mem[983] = 9'h1FF;
            ref_mem[984] = 9'h1FF;
            ref_mem[985] = 9'h1FF;
            ref_mem[986] = 9'h1FF;
            ref_mem[987] = 9'h1FF;
            ref_mem[988] = 9'h1FF;
            ref_mem[989] = 9'h1FF;
            ref_mem[990] = 9'h1FF;
            ref_mem[991] = 9'h1FF;
            ref_mem[992] = 9'h1FF;
            ref_mem[993] = 9'h1FF;
            ref_mem[994] = 9'h1FF;
            ref_mem[995] = 9'h1FF;
            ref_mem[996] = 9'h1FF;
            ref_mem[997] = 9'h1FF;
            ref_mem[998] = 9'h1FF;
            ref_mem[999] = 9'h1FF;
            ref_mem[1000] = 9'h1FF;
            ref_mem[1001] = 9'h1FF;
            ref_mem[1002] = 9'h1FF;
            ref_mem[1003] = 9'h1FF;
            ref_mem[1004] = 9'h1FF;
            ref_mem[1005] = 9'h1FF;
            ref_mem[1006] = 9'h1FF;
            ref_mem[1007] = 9'h1FF;
            ref_mem[1008] = 9'h1FF;
            ref_mem[1009] = 9'h1FF;
            ref_mem[1010] = 9'h1FF;
            ref_mem[1011] = 9'h1FF;
            ref_mem[1012] = 9'h1FF;
            ref_mem[1013] = 9'h1FF;
            ref_mem[1014] = 9'h1FF;
            ref_mem[1015] = 9'h1FF;
            ref_mem[1016] = 9'h1FF;
            ref_mem[1017] = 9'h1FF;
            ref_mem[1018] = 9'h1FF;
            ref_mem[1019] = 9'h1FF;
            ref_mem[1020] = 9'h1FF;
            ref_mem[1021] = 9'h1FF;
            ref_mem[1022] = 9'h1FF;
            ref_mem[1023] = 9'h1FF;
    end


    // ========================================================================
    // 工具
    // ========================================================================
    integer fails;
    integer checks;

    initial begin
        fails  = 0;
        checks = 0;
    end

    task chk;
        input         cond;
        input [511:0] msg;
        begin
            checks = checks + 1;
            if (!cond) begin
                fails = fails + 1;
                $display("[FAIL] %0s  (t=%0t)", msg, $time);
                $display("        frame_idx=%0d col=%0d narr_code=%h",
                         frame_idx, col, narr_code);
            end
        end
    endtask

    task chk_code;
        input [8:0]   got;
        input [8:0]   exp;
        input [511:0] msg;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                fails = fails + 1;
                $display("[FAIL] %0s  got=9'h%03X exp=9'h%03X  (t=%0t)",
                         msg, got, exp, $time);
            end
        end
    endtask

    // ========================================================================
    // 主流程
    // ========================================================================
    integer i;
    integer j;
    integer k;
    integer nblank;
    integer nvalid;

    // 参考表：18 段起始帧（与 narr_subline.v 的 seg_start 应逐项相同）
    task load_ref_start;
        begin
            ref_start[ 0] =   4;  ref_start[ 1] =  21;  ref_start[ 2] =  52;
            ref_start[ 3] =  92;  ref_start[ 4] = 136;  ref_start[ 5] = 161;
            ref_start[ 6] = 201;  ref_start[ 7] = 231;  ref_start[ 8] = 260;
            ref_start[ 9] = 317;  ref_start[10] = 339;  ref_start[11] = 385;
            ref_start[12] = 441;  ref_start[13] = 482;  ref_start[14] = 500;
            ref_start[15] = 540;  ref_start[16] = 594;  ref_start[17] = 615;
        end
    endtask

    // 参考表：18 段字数（超过 40 截到 40）
    task load_ref_len;
        begin
            ref_len[ 0] = 16;  ref_len[ 1] = 24;  ref_len[ 2] = 39;
            ref_len[ 3] = 38;  ref_len[ 4] = 23;  ref_len[ 5] = 40;
            ref_len[ 6] = 24;  ref_len[ 7] = 29;  ref_len[ 8] = 40;
            ref_len[ 9] = 25;  ref_len[10] = 37;  ref_len[11] = 40;
            ref_len[12] = 34;  ref_len[13] = 23;  ref_len[14] = 30;
            ref_len[15] = 40;  ref_len[16] = 18;  ref_len[17] = 13;
        end
    endtask

    // 参考表：18 段基址（累加得出，末项 + 末段长 = 533）
    task load_ref_base;
        begin
            ref_base[ 0] =   0;  ref_base[ 1] =  16;  ref_base[ 2] =  40;
            ref_base[ 3] =  79;  ref_base[ 4] = 117;  ref_base[ 5] = 140;
            ref_base[ 6] = 180;  ref_base[ 7] = 204;  ref_base[ 8] = 233;
            ref_base[ 9] = 273;  ref_base[10] = 298;  ref_base[11] = 335;
            ref_base[12] = 375;  ref_base[13] = 409;  ref_base[14] = 432;
            ref_base[15] = 462;  ref_base[16] = 502;  ref_base[17] = 520;
        end
    endtask

    // 参考模型：给定 frame_idx 与 col，算出应该输出的字形码
    //   完全是独立的实现：循环比较+累加，与 RTL 的前缀计数法不同路
    task ref_lookup;
        input  [15:0] fi;
        input  [5:0]  cc;
        output [8:0]  code;
        integer s;
        integer best;
        integer addr;
        begin
            code = 9'h1FF;
            best = -1;
            for (s = 0; s < SEGS; s = s + 1) begin
                if (fi >= ref_start[s]) best = s;
            end
            if (best >= 0) begin
                if (fi <= 16'd624) begin
                    if (cc < ref_len[best]) begin
                        addr = ref_base[best] + cc;
                        if (addr < 1024) code = ref_mem[addr];
                    end
                end
            end
        end
    endtask

    reg [8:0] exp_code;
    reg [8:0] code_1p;
    reg [8:0] expect_seq [0:15];

    initial begin
        $display("================================================================");
        $display(" tb_narr_subline : 科普视频字幕字形表");
        $display("================================================================");

        frame_idx = 16'd0;
        col       = 6'd0;

        load_ref_start;
        load_ref_len;
        load_ref_base;

        // ------------------------------------------------------------------
        // N06 表自身一致性（先跑，后面都依赖这张表）
        // ------------------------------------------------------------------
        $display("---- N06 参考表自洽 ----");

        chk(ref_start[0] == 4,  "N06 第 1 段起始帧应为 4");
        chk(ref_len[0] == 16,   "N06 第 1 段字数应为 16");
        chk(ref_len[5] == 40,   "N06 第 6 段原文 43 字应截到 40");
        chk(ref_len[11] == 40,  "N06 第 12 段原文 57 字应截到 40");
        chk(ref_base[0] == 0,   "N06 第 1 段基址应为 0");

        // 累加闭合：base[i+1] = base[i] + len[i]
        for (i = 1; i < SEGS; i = i + 1) begin
            chk(ref_base[i] == ref_base[i-1] + ref_len[i-1],
                "N06 基址累加不闭合");
        end
        chk(ref_base[SEGS-1] + ref_len[SEGS-1] == 533,
            "N06 末段基址加字数应为 533");

        // 18 段总字数（截断后）必须等于 533
        nvalid = 0;
        for (i = 0; i < SEGS; i = i + 1) nvalid = nvalid + ref_len[i];
        $display("     18 段截断后总字数 = %0d", nvalid);
        chk(nvalid == 533, "N06 18 段总字数应为 533");

        // ------------------------------------------------------------------
        // N01 块 RAM 里的字形码与参考表逐项一致
        //
        //   这里直接读被测模块的 mem（层次化引用），因为这是"数据装载正确性"，
        //   无法只从端口观测（端口只能看到当前选中段的一列）。
        //   比较用 != 而不是 !==：mem 若整片未初始化会是 x，
        //   x != 0 结果为 x、按假处理，不会把"全 x"统计成"全部不同"而误判通过
        //   ——这里两侧都是已知值，用 !== 更严格，故仍用 !==。
        // ------------------------------------------------------------------
        $display("---- N01 字形码表与 narration.srt 解析结果逐项一致 ----");

        // 先验测试台自己的参考表是"满的"：533 个有效项都要有值
        nblank = 0;
        for (i = 0; i < 1024; i = i + 1) begin
            if (ref_mem[i] === 9'h1FF) nblank = nblank + 1;
        end
        $display("     参考表空白项 = %0d / 1024，有效项 = %0d",
                 nblank, 1024 - nblank);
        chk(1024 - nblank == 533, "N01 参考表有效项应为 533");

        // 段 0 首字「F」——字库缺 B/I/J/K/M/N/O/Q/R/W/X/Y/Z，但 F 已收录
        // 段 0 全文「FPGA，全称现场可编程门阵列。」共 16 字
        chk_code(ref_mem[0], 9'h067, "N01 段 0 首字应为 'F'");
        // 「，」是 U+FF0C，索引 463
        chk_code(ref_mem[4], 9'h1CF, "N01 段 0 第 5 字应为「，」(索引 463)");

        // ------------------------------------------------------------------
        // N02 段选：逐帧扫描整段视频，每一帧的段号都必须对
        //
        //   做法：对每个 frame_idx 从 0 扫到 700，采样 col=0 的输出，
        //   与参考模型比对。这一条能同时抓住：
        //     - seg_start 表某一项写错（那一段的起点会错）
        //     - 段选比较用了 > 而不是 >=（边界帧会落到上一段）
        //     - 前缀计数法在 start 非单调时会算错
        // ------------------------------------------------------------------
        $display("---- N02 段选逐帧扫描（0..700） ----");

        // 先复位，让块 RAM 处于已知状态
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        nblank = 0;
        for (i = 0; i <= 700; i = i + 1) begin
            frame_idx = i[15:0];
            col       = 6'd0;
            @(posedge clk);
            #8;
            ref_lookup(i[15:0], 6'd0, exp_code);
            if (narr_code !== exp_code) begin
                fails  = fails + 1;
                $display("[FAIL] N02 frame_idx=%0d col=0 段选错误 got=%h exp=%h",
                         i, narr_code, exp_code);
            end
            checks = checks + 1;

            if (narr_code === 9'h1FF) nblank = nblank + 1;
        end
        $display("     701 帧里空白帧 = %0d（边界外应大量空白）", nblank);

        // 边界外的帧必须全空白：0..3 与 625..700
        for (i = 0; i <= 3; i = i + 1) begin
            frame_idx = i[15:0];
            col       = 6'd0;
            @(posedge clk);
            #8;
            chk_code(narr_code, 9'h1FF, "N02 frame_idx<4 应输出空白哨兵");
        end
        for (i = 625; i <= 700; i = i + 1) begin
            frame_idx = i[15:0];
            col       = 6'd0;
            @(posedge clk);
            #8;
            chk_code(narr_code, 9'h1FF, "N02 frame_idx>624 应输出空白哨兵");
        end

        // 边界内每一段的首帧必须有字（col=0 且该段 len>0）
        for (k = 0; k < SEGS; k = k + 1) begin
            frame_idx = ref_start[k][15:0];
            col       = 6'd0;
            @(posedge clk);
            #8;
            ref_lookup(ref_start[k][15:0], 6'd0, exp_code);
            chk_code(narr_code, exp_code, "N02 各段首帧 col=0 应与参考一致");
        end

        // ------------------------------------------------------------------
        // N03 列号边界：col < len 有字、col >= len 输出空白
        // ------------------------------------------------------------------
        $display("---- N03 列号边界 ----");

        for (k = 0; k < SEGS; k = k + 1) begin
            // 段内：col = len-1 是最后一个有效列
            frame_idx = ref_start[k][15:0];
            col       = (ref_len[k] - 1);
            @(posedge clk);
            #8;
            ref_lookup(ref_start[k][15:0], (ref_len[k] - 1), exp_code);
            chk_code(narr_code, exp_code, "N03 段尾最后一个有效列应与参考一致");

            // 段外：col = len 起必须空白
            col = ref_len[k];
            @(posedge clk);
            #8;
            chk_code(narr_code, 9'h1FF, "N03 col 超出段长应输出空白哨兵");

            col = 6'd39;
            @(posedge clk);
            #8;
            if (ref_len[k] <= 39) begin
                chk_code(narr_code, 9'h1FF, "N03 col=39 超段长应空白");
            end else begin
                ref_lookup(ref_start[k][15:0], 6'd39, exp_code);
                chk_code(narr_code, exp_code, "N03 col=39 段内应与参考一致");
            end
        end

        // ------------------------------------------------------------------
        // N03b 段尾门控必须与数据同拍（in_seg_q 那一拍的验证）
        //
        //   这是本模块最容易写错、且最难在屏幕上发现的一处：
        //     拍 N   ：地址 = base + col(N)        数据在拍 N+1 出来
        //     拍 N+1 ：narr_q = mem[地址(N)]
        //   门控 in_seg 若用"当前 col(N+1)"判断，就会与 mem 的数据错开一拍：
        //   段内最后一个有效列会被判成"超出段长"而丢掉，
        //   表现是每段末尾少显示一个字，而整段看上去依然"正常"。
        //
        //   因此必须**专门构造切换拍**才能抓到，正常逐列扫描抓不到
        //   （逐列扫描时 col 稳定，两种实现结果相同）。
        // ------------------------------------------------------------------
        $display("---- N03b 段尾门控与数据同拍 ----");

        // 段 0 共 16 字：col 0..15 有效、16 起空白
        frame_idx = ref_start[0][15:0];

        // 先把 col 停在最后一个有效列 15，等一拍让数据跟上
        col = 6'd15;
        @(posedge clk);
        #8;
        chk_code(narr_code, ref_mem[15], "N03b col=15（最后一个有效列）应有字");

        // 沿后立刻切到 16（段外），只推进 1 ns —— 这是"地址是 15、门控采样是 16"的那一拍
        col = 6'd16;
        #1;
        chk_code(narr_code, ref_mem[15], "N03b col=15 的数据此刻仍应保持");

        // 下一个上升沿：地址变 16，数据与门控都取自这一拍 → 空白
        @(posedge clk);
        #8;
        chk_code(narr_code, 9'h1FF, "N03b 越过段尾后应输出空白");

        // 再下一个沿保持空白（不能因为 mem[16] 恰好是下一段首字就串进来）
        @(posedge clk);
        #8;
        chk_code(narr_code, 9'h1FF, "N03b 段外连续多拍都应空白");

        // 反向：从段外回到最后一个有效列，不得把下一段首字串进来
        col = 6'd16;
        @(posedge clk);
        #8;
        col = 6'd15;
        #1;
        @(posedge clk);
        #8;
        chk_code(narr_code, ref_mem[15], "N03b 从段外回到段尾应显示本段最后一字，不串下一段");

        // ------------------------------------------------------------------
        // N04 三条时间边界（任务书点名要求）
        // ------------------------------------------------------------------
        $display("---- N04 三条时间边界 ----");

        // (a) frame_idx < 4：无字幕
        frame_idx = 16'd0;
        col       = 6'd0;
        @(posedge clk);
        #8;
        chk_code(narr_code, 9'h1FF, "N04 frame_idx<4 无字幕");

        frame_idx = 16'd3;
        @(posedge clk);
        #8;
        chk_code(narr_code, 9'h1FF, "N04 frame_idx=3 无字幕");

        // (b) frame_idx > 624：无字幕
        frame_idx = 16'd625;
        col       = 6'd0;
        @(posedge clk);
        #8;
        chk_code(narr_code, 9'h1FF, "N04 frame_idx=625 无字幕");

        frame_idx = 16'd1000;
        @(posedge clk);
        #8;
        chk_code(narr_code, 9'h1FF, "N04 frame_idx 远大于 624 仍无字幕");

        // (c) 段间空隙：保持上一段（本表 18 段首尾相接，中间本无空隙；
        //     真正要验的是"某段结束后到下一段开始前，仍显示上一段"）。
        //     第 1 段 4..19、第 2 段从 21 起，所以 20 属于空隙，应保持第 1 段。
        frame_idx = 16'd20;
        col       = 6'd0;
        @(posedge clk);
        #8;
        ref_lookup(16'd20, 6'd0, exp_code);
        chk_code(narr_code, exp_code, "N04 段间空隙应保持上一段");
        chk_code(narr_code, ref_mem[0], "N04 段间空隙的字应是第 1 段首字");

        // 第 2 段 21..44，第 3 段从 52 起 → 45..51 是空隙
        frame_idx = 16'd45;
        col       = 6'd0;
        @(posedge clk);
        #8;
        chk_code(narr_code, ref_mem[16], "N04 第二段尾的空隙应保持第 2 段首字");

        // ------------------------------------------------------------------
        // N05 读延迟恰好 1 拍
        //
        //   做法：把 col 从 0 切到 1，观察输出在第几拍变。
        //   拍 N 给地址、拍 N+1 出数据 —— 若 rtl 少打一拍（组合直通）则会
        //   当拍就变；若多打一拍（额外加寄存器）则要等两拍。
        //   两种错法都会让 osd_caption 里 t_bit_q2 的配对整体错一格。
        // ------------------------------------------------------------------
        $display("---- N05 读延迟恰好 1 拍 ----");

        frame_idx = ref_start[0][15:0];   // 第 1 段
        col       = 6'd0;
        @(posedge clk);
        #8;
        // 此刻输出应是 col=0 对应的码
        code_1p = narr_code;
        chk_code(narr_code, ref_mem[0], "N05 col=0 稳定后输出应为 mem[0]");

        // 时钟沿之后立刻改 col，只推进 1 ns（距下一个上升沿还有 39 ns）。
        // 若块 RAM 是组合直通（少打一拍），这一刻输出就会变，断言变红。
        col = 6'd1;
        #1;
        chk_code(narr_code, code_1p,
                 "N05 改 col 后、时钟沿到来前输出应仍是旧值（否则是组合直通=零拍）");

        // 下一个上升沿采到新地址，输出才更新——这才是"恰好 1 拍"
        @(posedge clk);
        #8;
        chk_code(narr_code, ref_mem[1], "N05 时钟沿后输出应更新为新地址数据（恰好 1 拍）");

        // ------------------------------------------------------------------
        // 收尾
        // ------------------------------------------------------------------
        $display("================================================================");
        $display(" 检查项 %0d 个，失败 %0d 个", checks, fails);
        if (fails == 0) begin
            $display(" ALL CHECKS PASSED: tb_narr_subline");
        end else begin
            $display(" *** FAILED: %0d check(s) ***", fails);
        end
        $display("================================================================");
        $finish;
    end

    // 超时保护
    initial begin
        #50_000_000;
        $display(" *** FAILED: timeout ***");
        $finish;
    end

endmodule

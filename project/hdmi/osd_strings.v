// ============================================================================
// 文件名  : osd_strings.v
// 所在位置: rtl/osd/osd_strings.v
// 所属层次: OSD 层 / 字符串表（由 scripts/gen_osd_strings.py 生成）
// 作者    : 智播校园项目组
// ============================================================================
// 【一】系统功能
//   B1 扩展项"图层叠加与字幕"要求屏幕上呈现标题、页面序号、播放状态和
//   滚动字幕四类文字。本模块是这四类文字的字符码来源。
//
// 【二】本模块功能
//   输入 {行号, 列号} → 输出该格位的 9 位字符码
//       line_sel <= 7 → bit[6:0] 是 ASCII 码，送 osd_font8x16（8 位点阵）
//       line_sel >= 8 → bit[8:0] 是 cjk16_charset.txt 的字形索引，送 cjk16_font
//       0x000 = 无字（空白），不占 case 项
//
// 【三】16 行怎么分配
//   line  0..7  ASCII 静态带：标题 / 序号 / PLAY..FAIL 六个状态
//   line  8..13 六段中文校园介绍，IMG n（n=1..6）对应 line 7+n
//   line 14..15 应急疏散文案：三段共 104 字（36+32+36，不含 2 个分隔空格），
//               拆两行由 osd_caption 每滚完一轮交替显示，一字不截断
//
//   三组行不能互换：坐标常量与 t_line 的译码都按这个分配写死。
//
// 【四】为什么是纯组合 case、以及为什么只有 9 位（t24 起）
//   本模块是一张只读的小表，输入地址来自寄存器（见 osd_caption 的
//   t_line/t_col），输出进字模 ROM 的地址或组合查表。综合成 LUT 树即可，
//   不需要块 RAM：真值表项数 373，远小于一块 BRAM9K 的 512 项颗粒度，
//   用 BRAM 反而要额外管 1 拍延迟——而 osd_caption 的三条 ASCII 带
//   是零打拍的（见 osd_caption 的【五】），多 1 拍会让整条文字错 1 像素。
//
//   位宽由 10 位收成 9 位：原 bit9 是「中/英」标志，但它恒等于 line_sel[3]，
//   是行号的冗余副本——全部 373 条目逐条实测满足
//       line_sel <= 7 → bit9 = 0（ASCII 静态带 line 0..7）
//       line_sel >= 8 → bit9 = 1（校园介绍 line 8..13、应急文案 line 14..15）
//   所以中英判定改由 osd_caption 用 t_line[3] 组合给出（is_cjk_eff），
//   本模块只负责「这一格是哪个字」。少 1 位换来：每行 64 选 1 的树每级
//   少 1 个 LUT，且下游不再有一条 fo=60 的 1 位复制网络（t7-B 违例路径）。
//
// 【五】自动生成，勿手改
//   改文案请改 assets/v2/masters/text/ 下的文本源，然后重跑
//       python scripts/gen_osd_strings.py --emit
//   手改本文件会在下次生成时被覆盖。
// ============================================================================
module osd_strings (
    input  wire [3:0] line_sel,    // 文本行 0..15
    input  wire [5:0] col,         // 字符列 0..63
    output reg  [8:0] char_code    // 9 位码：0x000 = 无字；中英由 line_sel[3] 判定
);

    always @(*) begin
        char_code = 9'h000;        // 默认无字
        case ({line_sel, col})

        // ---- line 0: ASCII 静态带
            10'd0   : char_code = 9'h053;   // col 0  'S'
            10'd1   : char_code = 9'h04D;   // col 1  'M'
            10'd2   : char_code = 9'h041;   // col 2  'A'
            10'd3   : char_code = 9'h052;   // col 3  'R'
            10'd4   : char_code = 9'h054;   // col 4  'T'
            10'd6   : char_code = 9'h043;   // col 6  'C'
            10'd7   : char_code = 9'h041;   // col 7  'A'
            10'd8   : char_code = 9'h04D;   // col 8  'M'
            10'd9   : char_code = 9'h050;   // col 9  'P'
            10'd10  : char_code = 9'h055;   // col 10 'U'
            10'd11  : char_code = 9'h053;   // col 11 'S'

        // ---- line 1: ASCII 静态带
            10'd64  : char_code = 9'h049;   // col 0  'I'
            10'd65  : char_code = 9'h04D;   // col 1  'M'
            10'd66  : char_code = 9'h047;   // col 2  'G'
            10'd68  : char_code = 9'h023;   // col 4  '#'
            10'd69  : char_code = 9'h02A;   // col 5  '*'

        // ---- line 2: ASCII 静态带
            10'd128 : char_code = 9'h050;   // col 0  'P'
            10'd129 : char_code = 9'h04C;   // col 1  'L'
            10'd130 : char_code = 9'h041;   // col 2  'A'
            10'd131 : char_code = 9'h059;   // col 3  'Y'

        // ---- line 3: ASCII 静态带
            10'd192 : char_code = 9'h050;   // col 0  'P'
            10'd193 : char_code = 9'h041;   // col 1  'A'
            10'd194 : char_code = 9'h055;   // col 2  'U'
            10'd195 : char_code = 9'h053;   // col 3  'S'
            10'd196 : char_code = 9'h045;   // col 4  'E'

        // ---- line 4: ASCII 静态带
            10'd256 : char_code = 9'h041;   // col 0  'A'
            10'd257 : char_code = 9'h055;   // col 1  'U'
            10'd258 : char_code = 9'h054;   // col 2  'T'
            10'd259 : char_code = 9'h04F;   // col 3  'O'

        // ---- line 5: ASCII 静态带
            10'd320 : char_code = 9'h057;   // col 0  'W'
            10'd321 : char_code = 9'h041;   // col 1  'A'
            10'd322 : char_code = 9'h049;   // col 2  'I'
            10'd323 : char_code = 9'h054;   // col 3  'T'
            10'd324 : char_code = 9'h049;   // col 4  'I'
            10'd325 : char_code = 9'h04E;   // col 5  'N'
            10'd326 : char_code = 9'h047;   // col 6  'G'

        // ---- line 6: ASCII 静态带
            10'd384 : char_code = 9'h045;   // col 0  'E'
            10'd385 : char_code = 9'h04D;   // col 1  'M'
            10'd386 : char_code = 9'h045;   // col 2  'E'
            10'd387 : char_code = 9'h052;   // col 3  'R'
            10'd388 : char_code = 9'h047;   // col 4  'G'
            10'd389 : char_code = 9'h045;   // col 5  'E'
            10'd390 : char_code = 9'h04E;   // col 6  'N'
            10'd391 : char_code = 9'h043;   // col 7  'C'
            10'd392 : char_code = 9'h059;   // col 8  'Y'

        // ---- line 7: ASCII 静态带
            10'd448 : char_code = 9'h046;   // col 0  'F'
            10'd449 : char_code = 9'h041;   // col 1  'A'
            10'd450 : char_code = 9'h049;   // col 2  'I'
            10'd451 : char_code = 9'h04C;   // col 3  'L'

        // ---- line 8: 校园介绍 1（IMG001）
            10'd512 : char_code = 9'h1CD;   // col 0  '黎' 字形 461
            10'd513 : char_code = 9'h127;   // col 1  '明' 字形 295
            10'd514 : char_code = 9'h126;   // col 2  '时' 字形 294
            10'd515 : char_code = 9'h029;   // col 3  '分' 字形 41
            10'd516 : char_code = 9'h1CF;   // col 4  '，' 字形 463
            10'd517 : char_code = 9'h12A;   // col 5  '晨' 字形 298
            10'd518 : char_code = 9'h0A6;   // col 6  '光' 字形 166
            10'd519 : char_code = 9'h187;   // col 7  '落' 字形 391
            10'd520 : char_code = 9'h047;   // col 8  '在' 字形 71
            10'd521 : char_code = 9'h11F;   // col 9  '教' 字形 287
            10'd522 : char_code = 9'h0E8;   // col 10 '学' 字形 232
            10'd523 : char_code = 9'h13B;   // col 11 '楼' 字形 315
            10'd524 : char_code = 9'h043;   // col 12 '上' 字形 67
            10'd525 : char_code = 9'h077;   // col 13 '。' 字形 119
            10'd526 : char_code = 9'h16F;   // col 14 '穿' 字形 367
            10'd527 : char_code = 9'h1A5;   // col 15 '过' 字形 421
            10'd528 : char_code = 9'h0F1;   // col 16 '山' 字形 241
            10'd529 : char_code = 9'h07E;   // col 17 '丘' 字形 126
            10'd530 : char_code = 9'h07B;   // col 18 '与' 字形 123
            10'd531 : char_code = 9'h141;   // col 19 '水' 字形 321
            10'd532 : char_code = 9'h0F2;   // col 20 '岸' 字形 242
            10'd533 : char_code = 9'h1CF;   // col 21 '，' 字形 463
            10'd534 : char_code = 9'h19C;   // col 22 '走' 字形 412
            10'd535 : char_code = 9'h1AB;   // col 23 '进' 字形 427
            10'd536 : char_code = 9'h00A;   // col 24 '校' 字形 10
            10'd537 : char_code = 9'h1BD;   // col 25 '门' 字形 445
            10'd538 : char_code = 9'h1CF;   // col 26 '，' 字形 463
            10'd539 : char_code = 9'h044;   // col 27 '一' 字形 68
            10'd540 : char_code = 9'h0E1;   // col 28 '天' 字形 225
            10'd541 : char_code = 9'h15E;   // col 29 '的' 字形 350
            10'd542 : char_code = 9'h0E8;   // col 30 '学' 字形 232
            10'd543 : char_code = 9'h086;   // col 31 '习' 字形 134
            10'd544 : char_code = 9'h08F;   // col 32 '从' 字形 143
            10'd545 : char_code = 9'h1AA;   // col 33 '这' 字形 426
            10'd546 : char_code = 9'h1B6;   // col 34 '里' 字形 438
            10'd547 : char_code = 9'h036;   // col 35 '开' 字形 54
            10'd548 : char_code = 9'h0E6;   // col 36 '始' 字形 230
            10'd549 : char_code = 9'h077;   // col 37 '。' 字形 119

        // ---- line 9: 校园介绍 2（IMG002）
            10'd576 : char_code = 9'h03C;   // col 0  '图' 字形 60
            10'd577 : char_code = 9'h00C;   // col 1  '书' 字形 12
            10'd578 : char_code = 9'h1CB;   // col 2  '馆' 字形 459
            10'd579 : char_code = 9'h15E;   // col 3  '的' 字形 350
            10'd580 : char_code = 9'h14D;   // col 4  '灯' 字形 333
            10'd581 : char_code = 9'h001;   // col 5  '常' 字形 1
            10'd582 : char_code = 9'h017;   // col 6  '年' 字形 23
            10'd583 : char_code = 9'h026;   // col 7  '亮' 字形 38
            10'd584 : char_code = 9'h164;   // col 8  '着' 字形 356
            10'd585 : char_code = 9'h077;   // col 9  '。' 字形 119
            10'd586 : char_code = 9'h1BC;   // col 10 '长' 字形 444
            10'd587 : char_code = 9'h170;   // col 11 '窗' 字形 368
            10'd588 : char_code = 9'h046;   // col 12 '下' 字形 70
            10'd589 : char_code = 9'h1CF;   // col 13 '，' 字形 463
            10'd590 : char_code = 9'h044;   // col 14 '一' 字形 68
            10'd591 : char_code = 9'h12F;   // col 15 '本' 字形 303
            10'd592 : char_code = 9'h11B;   // col 16 '摊' 字形 283
            10'd593 : char_code = 9'h036;   // col 17 '开' 字形 54
            10'd594 : char_code = 9'h047;   // col 18 '在' 字形 71
            10'd595 : char_code = 9'h139;   // col 19 '桌' 字形 313
            10'd596 : char_code = 9'h1C7;   // col 20 '面' 字形 455
            10'd597 : char_code = 9'h043;   // col 21 '上' 字形 67
            10'd598 : char_code = 9'h15E;   // col 22 '的' 字形 350
            10'd599 : char_code = 9'h00C;   // col 23 '书' 字形 12
            10'd600 : char_code = 9'h1CF;   // col 24 '，' 字形 463
            10'd601 : char_code = 9'h10D;   // col 25 '把' 字形 269
            10'd602 : char_code = 9'h01A;   // col 26 '安' 字形 26
            10'd603 : char_code = 9'h1C6;   // col 27 '静' 字形 454
            10'd604 : char_code = 9'h15E;   // col 28 '的' 字形 350
            10'd605 : char_code = 9'h16E;   // col 29 '空' 字形 366
            10'd606 : char_code = 9'h1BF;   // col 30 '间' 字形 447
            10'd607 : char_code = 9'h11C;   // col 31 '撑' 字形 284
            10'd608 : char_code = 9'h106;   // col 32 '成' 字形 262
            10'd609 : char_code = 9'h12B;   // col 33 '更' 字形 299
            10'd610 : char_code = 9'h0E0;   // col 34 '大' 字形 224
            10'd611 : char_code = 9'h15E;   // col 35 '的' 字形 350
            10'd612 : char_code = 9'h07D;   // col 36 '世' 字形 125
            10'd613 : char_code = 9'h15C;   // col 37 '界' 字形 348
            10'd614 : char_code = 9'h077;   // col 38 '。' 字形 119

        // ---- line 10: 校园介绍 3（IMG003）
            10'd640 : char_code = 9'h00E;   // col 0  '创' 字形 14
            10'd641 : char_code = 9'h00F;   // col 1  '客' 字形 15
            10'd642 : char_code = 9'h010;   // col 2  '工' 字形 16
            10'd643 : char_code = 9'h011;   // col 3  '坊' 字形 17
            10'd644 : char_code = 9'h1B6;   // col 4  '里' 字形 438
            10'd645 : char_code = 9'h1CF;   // col 5  '，' 字形 463
            10'd646 : char_code = 9'h186;   // col 6  '芯' 字形 390
            10'd647 : char_code = 9'h03D;   // col 7  '片' 字形 61
            10'd648 : char_code = 9'h07B;   // col 8  '与' 字形 123
            10'd649 : char_code = 9'h15A;   // col 9  '电' 字形 346
            10'd650 : char_code = 9'h19E;   // col 10 '路' 字形 414
            10'd651 : char_code = 9'h10D;   // col 11 '把' 字形 269
            10'd652 : char_code = 9'h104;   // col 12 '想' 字形 260
            10'd653 : char_code = 9'h143;   // col 13 '法' 字形 323
            10'd654 : char_code = 9'h116;   // col 14 '接' 字形 278
            10'd655 : char_code = 9'h043;   // col 15 '上' 字形 67
            10'd656 : char_code = 9'h154;   // col 16 '现' 字形 340
            10'd657 : char_code = 9'h0EB;   // col 17 '实' 字形 235
            10'd658 : char_code = 9'h077;   // col 18 '。' 字形 119
            10'd659 : char_code = 9'h19C;   // col 19 '走' 字形 412
            10'd660 : char_code = 9'h176;   // col 20 '线' 字形 374
            10'd661 : char_code = 9'h08F;   // col 21 '从' 字形 143
            10'd662 : char_code = 9'h1AA;   // col 22 '这' 字形 426
            10'd663 : char_code = 9'h1B6;   // col 23 '里' 字形 438
            10'd664 : char_code = 9'h0FA;   // col 24 '延' 字形 250
            10'd665 : char_code = 9'h099;   // col 25 '伸' 字形 153
            10'd666 : char_code = 9'h1CF;   // col 26 '，' 字形 463
            10'd667 : char_code = 9'h00E;   // col 27 '创' 字形 14
            10'd668 : char_code = 9'h105;   // col 28 '意' 字形 261
            10'd669 : char_code = 9'h0CA;   // col 29 '变' 字形 202
            10'd670 : char_code = 9'h106;   // col 30 '成' 字形 262
            10'd671 : char_code = 9'h162;   // col 31 '看' 字形 354
            10'd672 : char_code = 9'h100;   // col 32 '得' 字形 256
            10'd673 : char_code = 9'h18C;   // col 33 '见' 字形 396
            10'd674 : char_code = 9'h15E;   // col 34 '的' 字形 350
            10'd675 : char_code = 9'h09D;   // col 35 '作' 字形 157
            10'd676 : char_code = 9'h0D1;   // col 36 '品' 字形 209
            10'd677 : char_code = 9'h077;   // col 37 '。' 字形 119

        // ---- line 11: 校园介绍 4（IMG004）
            10'd704 : char_code = 9'h079;   // col 0  '三' 字形 121
            10'd705 : char_code = 9'h0CD;   // col 1  '台' 字形 205
            10'd706 : char_code = 9'h1CA;   // col 2  '风' 字形 458
            10'd707 : char_code = 9'h130;   // col 3  '机' 字形 304
            10'd708 : char_code = 9'h07B;   // col 4  '与' 字形 123
            10'd709 : char_code = 9'h106;   // col 5  '成' 字形 262
            10'd710 : char_code = 9'h115;   // col 6  '排' 字形 277
            10'd711 : char_code = 9'h0A6;   // col 7  '光' 字形 166
            10'd712 : char_code = 9'h096;   // col 8  '伏' 字形 150
            10'd713 : char_code = 9'h133;   // col 9  '板' 字形 307
            10'd714 : char_code = 9'h1CF;   // col 10 '，' 字形 463
            10'd715 : char_code = 9'h10D;   // col 11 '把' 字形 269
            10'd716 : char_code = 9'h1CA;   // col 12 '风' 字形 458
            10'd717 : char_code = 9'h0D0;   // col 13 '和' 字形 208
            10'd718 : char_code = 9'h1C2;   // col 14 '阳' 字形 450
            10'd719 : char_code = 9'h0A6;   // col 15 '光' 字形 166
            10'd720 : char_code = 9'h0CA;   // col 16 '变' 字形 202
            10'd721 : char_code = 9'h106;   // col 17 '成' 字形 262
            10'd722 : char_code = 9'h15A;   // col 18 '电' 字形 346
            10'd723 : char_code = 9'h077;   // col 19 '。' 字形 119
            10'd724 : char_code = 9'h09B;   // col 20 '低' 字形 155
            10'd725 : char_code = 9'h169;   // col 21 '碳' 字形 361
            10'd726 : char_code = 9'h07A;   // col 22 '不' 字形 122
            10'd727 : char_code = 9'h129;   // col 23 '是' 字形 297
            10'd728 : char_code = 9'h0CB;   // col 24 '口' 字形 203
            10'd729 : char_code = 9'h04F;   // col 25 '号' 字形 79
            10'd730 : char_code = 9'h1CF;   // col 26 '，' 字形 463
            10'd731 : char_code = 9'h129;   // col 27 '是' 字形 297
            10'd732 : char_code = 9'h00A;   // col 28 '校' 字形 10
            10'd733 : char_code = 9'h00B;   // col 29 '园' 字形 11
            10'd734 : char_code = 9'h1B6;   // col 30 '里' 字形 438
            10'd735 : char_code = 9'h181;   // col 31 '自' 字形 385
            10'd736 : char_code = 9'h150;   // col 32 '然' 字形 336
            10'd737 : char_code = 9'h15E;   // col 33 '的' 字形 350
            10'd738 : char_code = 9'h044;   // col 34 '一' 字形 68
            10'd739 : char_code = 9'h1B3;   // col 35 '部' 字形 435
            10'd740 : char_code = 9'h029;   // col 36 '分' 字形 41
            10'd741 : char_code = 9'h077;   // col 37 '。' 字形 119

        // ---- line 12: 校园介绍 5（IMG005）
            10'd768 : char_code = 9'h162;   // col 0  '看' 字形 354
            10'd769 : char_code = 9'h0CD;   // col 1  '台' 字形 205
            10'd770 : char_code = 9'h043;   // col 2  '上' 字形 67
            10'd771 : char_code = 9'h0D7;   // col 3  '坐' 字形 215
            10'd772 : char_code = 9'h14B;   // col 4  '满' 字形 331
            10'd773 : char_code = 9'h087;   // col 5  '了' 字形 135
            10'd774 : char_code = 9'h08C;   // col 6  '人' 字形 140
            10'd775 : char_code = 9'h1CF;   // col 7  '，' 字形 463
            10'd776 : char_code = 9'h19D;   // col 8  '跑' 字形 413
            10'd777 : char_code = 9'h1B2;   // col 9  '道' 字形 434
            10'd778 : char_code = 9'h043;   // col 10 '上' 字形 67
            10'd779 : char_code = 9'h12D;   // col 11 '有' 字形 301
            10'd780 : char_code = 9'h08C;   // col 12 '人' 字形 140
            10'd781 : char_code = 9'h023;   // col 13 '正' 字形 35
            10'd782 : char_code = 9'h0B0;   // col 14 '冲' 字形 176
            10'd783 : char_code = 9'h1A5;   // col 15 '过' 字形 421
            10'd784 : char_code = 9'h0FC;   // col 16 '弯' 字形 252
            10'd785 : char_code = 9'h1B2;   // col 17 '道' 字形 434
            10'd786 : char_code = 9'h077;   // col 18 '。' 字形 119
            10'd787 : char_code = 9'h140;   // col 19 '每' 字形 320
            10'd788 : char_code = 9'h044;   // col 20 '一' 字形 68
            10'd789 : char_code = 9'h13C;   // col 21 '次' 字形 316
            10'd790 : char_code = 9'h0E4;   // col 22 '奔' 字形 228
            10'd791 : char_code = 9'h19D;   // col 23 '跑' 字形 413
            10'd792 : char_code = 9'h1CF;   // col 24 '，' 字形 463
            10'd793 : char_code = 9'h1B4;   // col 25 '都' 字形 436
            10'd794 : char_code = 9'h191;   // col 26 '让' 字形 401
            10'd795 : char_code = 9'h00A;   // col 27 '校' 字形 10
            10'd796 : char_code = 9'h00B;   // col 28 '园' 字形 11
            10'd797 : char_code = 9'h12B;   // col 29 '更' 字形 299
            10'd798 : char_code = 9'h12D;   // col 30 '有' 字形 301
            10'd799 : char_code = 9'h146;   // col 31 '活' 字形 326
            10'd800 : char_code = 9'h0BC;   // col 32 '力' 字形 188
            10'd801 : char_code = 9'h077;   // col 33 '。' 字形 119

        // ---- line 13: 校园介绍 6（IMG006）
            10'd832 : char_code = 9'h0DF;   // col 0  '夜' 字形 223
            10'd833 : char_code = 9'h013;   // col 1  '色' 字形 19
            10'd834 : char_code = 9'h1B6;   // col 2  '里' 字形 438
            10'd835 : char_code = 9'h15E;   // col 3  '的' 字形 350
            10'd836 : char_code = 9'h00A;   // col 4  '校' 字形 10
            10'd837 : char_code = 9'h00B;   // col 5  '园' 字形 11
            10'd838 : char_code = 9'h09F;   // col 6  '依' 字形 159
            10'd839 : char_code = 9'h150;   // col 7  '然' 字形 336
            10'd840 : char_code = 9'h127;   // col 8  '明' 字形 295
            10'd841 : char_code = 9'h026;   // col 9  '亮' 字形 38
            10'd842 : char_code = 9'h077;   // col 10 '。' 字形 119
            10'd843 : char_code = 9'h19E;   // col 11 '路' 字形 414
            10'd844 : char_code = 9'h1A4;   // col 12 '边' 字形 420
            10'd845 : char_code = 9'h15E;   // col 13 '的' 字形 350
            10'd846 : char_code = 9'h14D;   // col 14 '灯' 字形 333
            10'd847 : char_code = 9'h1AC;   // col 15 '连' 字形 428
            10'd848 : char_code = 9'h106;   // col 16 '成' 字形 262
            10'd849 : char_code = 9'h044;   // col 17 '一' 字形 68
            10'd850 : char_code = 9'h132;   // col 18 '条' 字形 306
            10'd851 : char_code = 9'h01A;   // col 19 '安' 字形 26
            10'd852 : char_code = 9'h0A8;   // col 20 '全' 字形 168
            10'd853 : char_code = 9'h1AF;   // col 21 '通' 字形 431
            10'd854 : char_code = 9'h1B2;   // col 22 '道' 字形 434
            10'd855 : char_code = 9'h1CF;   // col 23 '，' 字形 463
            10'd856 : char_code = 9'h191;   // col 24 '让' 字形 401
            10'd857 : char_code = 9'h140;   // col 25 '每' 字形 320
            10'd858 : char_code = 9'h044;   // col 26 '一' 字形 68
            10'd859 : char_code = 9'h13E;   // col 27 '步' 字形 318
            10'd860 : char_code = 9'h1B4;   // col 28 '都' 字形 436
            10'd861 : char_code = 9'h12B;   // col 29 '更' 字形 299
            10'd862 : char_code = 9'h01A;   // col 30 '安' 字形 26
            10'd863 : char_code = 9'h101;   // col 31 '心' 字形 257
            10'd864 : char_code = 9'h077;   // col 32 '。' 字形 119

        // ---- line 14: 应急疏散文案 1/2
            10'd896 : char_code = 9'h006;   // col 0  '应' 字形 6
            10'd897 : char_code = 9'h007;   // col 1  '急' 字形 7
            10'd898 : char_code = 9'h002;   // col 2  '模' 字形 2
            10'd899 : char_code = 9'h003;   // col 3  '式' 字形 3
            10'd900 : char_code = 9'h0F3;   // col 4  '已' 字形 243
            10'd901 : char_code = 9'h038;   // col 5  '启' 字形 56
            10'd902 : char_code = 9'h015;   // col 6  '动' 字形 21
            10'd903 : char_code = 9'h077;   // col 7  '。' 字形 119
            10'd904 : char_code = 9'h04A;   // col 8  '请' 字形 74
            10'd905 : char_code = 9'h142;   // col 9  '沿' 字形 322
            10'd906 : char_code = 9'h12C;   // col 10 '最' 字形 300
            10'd907 : char_code = 9'h1A7;   // col 11 '近' 字形 423
            10'd908 : char_code = 9'h15E;   // col 12 '的' 字形 350
            10'd909 : char_code = 9'h01A;   // col 13 '安' 字形 26
            10'd910 : char_code = 9'h0A8;   // col 14 '全' 字形 168
            10'd911 : char_code = 9'h0B2;   // col 15 '出' 字形 178
            10'd912 : char_code = 9'h0CB;   // col 16 '口' 字形 203
            10'd913 : char_code = 9'h12D;   // col 17 '有' 字形 301
            10'd914 : char_code = 9'h0F8;   // col 18 '序' 字形 248
            10'd915 : char_code = 9'h11D;   // col 19 '撤' 字形 285
            10'd916 : char_code = 9'h16A;   // col 20 '离' 字形 362
            10'd917 : char_code = 9'h1CF;   // col 21 '，' 字形 463
            10'd918 : char_code = 9'h07A;   // col 22 '不' 字形 122
            10'd919 : char_code = 9'h18B;   // col 23 '要' 字形 395
            10'd920 : char_code = 9'h083;   // col 24 '乘' 字形 131
            10'd921 : char_code = 9'h0D7;   // col 25 '坐' 字形 215
            10'd922 : char_code = 9'h15A;   // col 26 '电' 字形 346
            10'd923 : char_code = 9'h13A;   // col 27 '梯' 字形 314
            10'd924 : char_code = 9'h1CF;   // col 28 '，' 字形 463
            10'd925 : char_code = 9'h07A;   // col 29 '不' 字形 122
            10'd926 : char_code = 9'h18B;   // col 30 '要' 字形 395
            10'd927 : char_code = 9'h1A8;   // col 31 '返' 字形 424
            10'd928 : char_code = 9'h0D4;   // col 32 '回' 字形 212
            10'd929 : char_code = 9'h0C9;   // col 33 '取' 字形 201
            10'd930 : char_code = 9'h151;   // col 34 '物' 字形 337
            10'd931 : char_code = 9'h077;   // col 35 '。' 字形 119
            10'd933 : char_code = 9'h149;   // col 37 '消' 字形 329
            10'd934 : char_code = 9'h1C1;   // col 38 '防' 字形 449
            10'd935 : char_code = 9'h1AF;   // col 39 '通' 字形 431
            10'd936 : char_code = 9'h1B2;   // col 40 '道' 字形 434
            10'd937 : char_code = 9'h04A;   // col 41 '请' 字形 74
            10'd938 : char_code = 9'h0A0;   // col 42 '保' 字形 160
            10'd939 : char_code = 9'h110;   // col 43 '持' 字形 272
            10'd940 : char_code = 9'h15B;   // col 44 '畅' 字形 347
            10'd941 : char_code = 9'h1AF;   // col 45 '通' 字形 431
            10'd942 : char_code = 9'h1CF;   // col 46 '，' 字形 463
            10'd943 : char_code = 9'h0B4;   // col 47 '切' 字形 180
            10'd944 : char_code = 9'h0BF;   // col 48 '勿' 字形 191
            10'd945 : char_code = 9'h0DB;   // col 49 '堆' 字形 219
            10'd946 : char_code = 9'h040;   // col 50 '放' 字形 64
            10'd947 : char_code = 9'h131;   // col 51 '杂' 字形 305
            10'd948 : char_code = 9'h151;   // col 52 '物' 字形 337
            10'd949 : char_code = 9'h107;   // col 53 '或' 字形 263
            10'd950 : char_code = 9'h042;   // col 54 '停' 字形 66
            10'd951 : char_code = 9'h040;   // col 55 '放' 字形 64
            10'd952 : char_code = 9'h19F;   // col 56 '车' 字形 415
            10'd953 : char_code = 9'h1A1;   // col 57 '辆' 字形 417
            10'd954 : char_code = 9'h077;   // col 58 '。' 字形 119
            10'd955 : char_code = 9'h15D;   // col 59 '疏' 字形 349
            10'd956 : char_code = 9'h120;   // col 60 '散' 字形 288
            10'd957 : char_code = 9'h126;   // col 61 '时' 字形 294
            10'd958 : char_code = 9'h04A;   // col 62 '请' 字形 74
            10'd959 : char_code = 9'h0BF;   // col 63 '勿' 字形 191

        // ---- line 15: 应急疏散文案 2/2
            10'd960 : char_code = 9'h10E;   // col 0  '拥' 字形 270
            10'd961 : char_code = 9'h113;   // col 1  '挤' 字形 275
            10'd962 : char_code = 9'h118;   // col 2  '推' 字形 280
            10'd963 : char_code = 9'h11A;   // col 3  '搡' 字形 282
            10'd964 : char_code = 9'h077;   // col 4  '。' 字形 119
            10'd966 : char_code = 9'h0E5;   // col 6  '如' 字形 229
            10'd967 : char_code = 9'h0C8;   // col 7  '发' 字形 200
            10'd968 : char_code = 9'h154;   // col 8  '现' 字形 340
            10'd969 : char_code = 9'h14C;   // col 9  '火' 字形 332
            10'd970 : char_code = 9'h103;   // col 10 '情' 字形 259
            10'd971 : char_code = 9'h1CF;   // col 11 '，' 字形 463
            10'd972 : char_code = 9'h04A;   // col 12 '请' 字形 74
            10'd973 : char_code = 9'h171;   // col 13 '立' 字形 369
            10'd974 : char_code = 9'h0C2;   // col 14 '即' 字形 194
            10'd975 : char_code = 9'h112;   // col 15 '按' 字形 274
            10'd976 : char_code = 9'h046;   // col 16 '下' 字形 70
            10'd977 : char_code = 9'h108;   // col 17 '手' 字形 264
            10'd978 : char_code = 9'h015;   // col 18 '动' 字形 21
            10'd979 : char_code = 9'h01F;   // col 19 '报' 字形 31
            10'd980 : char_code = 9'h020;   // col 20 '警' 字形 32
            10'd981 : char_code = 9'h112;   // col 21 '按' 字形 274
            10'd982 : char_code = 9'h1B9;   // col 22 '钮' 字形 441
            10'd983 : char_code = 9'h1CF;   // col 23 '，' 字形 463
            10'd984 : char_code = 9'h0F6;   // col 24 '并' 字形 246
            10'd985 : char_code = 9'h10F;   // col 25 '拨' 字形 271
            10'd986 : char_code = 9'h109;   // col 26 '打' 字形 265
            10'd987 : char_code = 9'h00A;   // col 27 '校' 字形 10
            10'd988 : char_code = 9'h0AD;   // col 28 '内' 字形 173
            10'd989 : char_code = 9'h006;   // col 29 '应' 字形 6
            10'd990 : char_code = 9'h007;   // col 30 '急' 字形 7
            10'd991 : char_code = 9'h15A;   // col 31 '电' 字形 346
            10'd992 : char_code = 9'h195;   // col 32 '话' 字形 405
            10'd993 : char_code = 9'h077;   // col 33 '。' 字形 119
            10'd994 : char_code = 9'h04A;   // col 34 '请' 字形 74
            10'd995 : char_code = 9'h12E;   // col 35 '服' 字形 302
            10'd996 : char_code = 9'h08F;   // col 36 '从' 字形 143
            10'd997 : char_code = 9'h154;   // col 37 '现' 字形 340
            10'd998 : char_code = 9'h0D6;   // col 38 '场' 字形 214
            10'd999 : char_code = 9'h0FB;   // col 39 '引' 字形 251
            10'd1000: char_code = 9'h0EC;   // col 40 '导' 字形 236
            10'd1001: char_code = 9'h077;   // col 41 '。' 字形 119

            default: char_code = 9'h000;
        endcase
    end

endmodule

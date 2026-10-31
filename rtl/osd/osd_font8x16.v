// ============================================================================
// 文件名  : osd_font8x16.v
// 所在位置: rtl/osd/osd_font8x16.v
// 所属层次: OSD 层 / 8x16 点阵字模 ROM
// 作者    : 智播校园项目组
// ============================================================================
// 【一】系统功能
//   智播校园把 SD 卡图片送上 HDMI。B1 扩展项要求"图层叠加与字幕"，
//   字幕必须是**真字符**——旧的 12 格方块位图只能表示二进制状态，
//   拼不出"PLAY""IMG 05/12"这种文字。
//   本模块是字幕通路的第一级: 给字符码和行号，返回该行 8 个像素。

// 【二】本模块功能
//   输入 char_code[5:0] + row[3:0] → 输出 pixels[7:0]（bit7 = 最左像素）
//   纯组合，无时钟、无状态、同拍出图。

// 【三】为什么索引是 char_code[5:0] 而不是 char_code-0x20
//   本 ROM 收录的字符集（空格、'-' '.' '/'、'0'-'9'、':'、'A'-'Z'）
//   全部落在 ASCII 0x20..0x5F，**低 6 位互不相同**:
//       ' '(0x20) -> 低6位 32      '@'(0x40) -> 低6位 0
//       'A'(0x41) -> 低6位 1       'Z'(0x5A) -> 低6位 26
//   所以上层把字符码低 6 位直接接进来即可，**省掉一个减法器**。
//   未收录的索引走 default 输出 0x00，屏幕上表现为空白而不是乱码。

// 【四】为什么是 8x16 而不是 8x8
//   实测 8x8 下 'A' 糊成实心块、'B'/'D'/'8' 互相难分，字幕读不出来。
//   8x16 是经典 VGA 文本模式规格，笔画能拉开，是 640x480 单行字幕的
//   合适粒度。代价是每字形 16 行常量，但字符集只有 41 个，总量可控。

// 【五】字形来源与许可
//   点阵由 scripts/gen_osd_font8.py 从 Consolas Bold 栅格化生成后固化
//   为本 ROM；运行时**不加载任何字体文件**。
//   重新生成: python scripts/gen_osd_font8.py --emit

// 【六】资源代价
//   41 字形 x 16 行 x 8 bit = 5248 bit 常量，综合成 LUT 查表。
//   不用 BRAM: BRAM 读延迟 1 拍，而字幕必须与像素同拍组合出图。
// ============================================================================
module osd_font8x16 (
    input  wire [5:0] char_code,   // 字符码低 6 位（ASCII & 0x3F）
    input  wire [3:0] row,         // 字形行号 0..15（0 = 最上一行）
    output reg  [7:0] pixels       // 该行 8 个像素，bit7 = 最左
);

    // 一项 = {字符低6位, 行号} 共 10 bit；未列出的组合输出 0x00
    always @(*) begin
        pixels = 8'h00;            // 默认空白（未收录字符显示为空）
        case ({char_code, row})
            // 1 : 'A'
            10'd16 : pixels = 8'h00;
            10'd17 : pixels = 8'h00;
            10'd18 : pixels = 8'h00;
            10'd19 : pixels = 8'h38;
            10'd20 : pixels = 8'h3C;
            10'd21 : pixels = 8'h3C;
            10'd22 : pixels = 8'h2C;
            10'd23 : pixels = 8'h6C;
            10'd24 : pixels = 8'h66;
            10'd25 : pixels = 8'h7E;
            10'd26 : pixels = 8'hC6;
            10'd27 : pixels = 8'hC3;
            10'd28 : pixels = 8'h00;
            10'd29 : pixels = 8'h00;
            10'd30 : pixels = 8'h00;
            10'd31 : pixels = 8'h00;
            // 2 : 'B'
            10'd32 : pixels = 8'h00;
            10'd33 : pixels = 8'h00;
            10'd34 : pixels = 8'h00;
            10'd35 : pixels = 8'h7C;
            10'd36 : pixels = 8'h66;
            10'd37 : pixels = 8'h66;
            10'd38 : pixels = 8'h66;
            10'd39 : pixels = 8'h7C;
            10'd40 : pixels = 8'h66;
            10'd41 : pixels = 8'h66;
            10'd42 : pixels = 8'h66;
            10'd43 : pixels = 8'h7C;
            10'd44 : pixels = 8'h00;
            10'd45 : pixels = 8'h00;
            10'd46 : pixels = 8'h00;
            10'd47 : pixels = 8'h00;
            // 3 : 'C'
            10'd48 : pixels = 8'h00;
            10'd49 : pixels = 8'h00;
            10'd50 : pixels = 8'h00;
            10'd51 : pixels = 8'h3C;
            10'd52 : pixels = 8'h72;
            10'd53 : pixels = 8'h60;
            10'd54 : pixels = 8'h60;
            10'd55 : pixels = 8'hE0;
            10'd56 : pixels = 8'h60;
            10'd57 : pixels = 8'h60;
            10'd58 : pixels = 8'h72;
            10'd59 : pixels = 8'h3C;
            10'd60 : pixels = 8'h00;
            10'd61 : pixels = 8'h00;
            10'd62 : pixels = 8'h00;
            10'd63 : pixels = 8'h00;
            // 4 : 'D'
            10'd64 : pixels = 8'h00;
            10'd65 : pixels = 8'h00;
            10'd66 : pixels = 8'h00;
            10'd67 : pixels = 8'hFC;
            10'd68 : pixels = 8'hCE;
            10'd69 : pixels = 8'hC6;
            10'd70 : pixels = 8'hC6;
            10'd71 : pixels = 8'hC6;
            10'd72 : pixels = 8'hC6;
            10'd73 : pixels = 8'hC6;
            10'd74 : pixels = 8'hCE;
            10'd75 : pixels = 8'hF8;
            10'd76 : pixels = 8'h00;
            10'd77 : pixels = 8'h00;
            10'd78 : pixels = 8'h00;
            10'd79 : pixels = 8'h00;
            // 5 : 'E'
            10'd80 : pixels = 8'h00;
            10'd81 : pixels = 8'h00;
            10'd82 : pixels = 8'h00;
            10'd83 : pixels = 8'h7E;
            10'd84 : pixels = 8'h60;
            10'd85 : pixels = 8'h60;
            10'd86 : pixels = 8'h60;
            10'd87 : pixels = 8'h7E;
            10'd88 : pixels = 8'h60;
            10'd89 : pixels = 8'h60;
            10'd90 : pixels = 8'h60;
            10'd91 : pixels = 8'h7E;
            10'd92 : pixels = 8'h00;
            10'd93 : pixels = 8'h00;
            10'd94 : pixels = 8'h00;
            10'd95 : pixels = 8'h00;
            // 6 : 'F'
            10'd96 : pixels = 8'h00;
            10'd97 : pixels = 8'h00;
            10'd98 : pixels = 8'h00;
            10'd99 : pixels = 8'h7E;
            10'd100: pixels = 8'h60;
            10'd101: pixels = 8'h60;
            10'd102: pixels = 8'h60;
            10'd103: pixels = 8'h7C;
            10'd104: pixels = 8'h60;
            10'd105: pixels = 8'h60;
            10'd106: pixels = 8'h60;
            10'd107: pixels = 8'h60;
            10'd108: pixels = 8'h00;
            10'd109: pixels = 8'h00;
            10'd110: pixels = 8'h00;
            10'd111: pixels = 8'h00;
            // 7 : 'G'
            10'd112: pixels = 8'h00;
            10'd113: pixels = 8'h00;
            10'd114: pixels = 8'h00;
            10'd115: pixels = 8'h3C;
            10'd116: pixels = 8'h62;
            10'd117: pixels = 8'h60;
            10'd118: pixels = 8'hC0;
            10'd119: pixels = 8'hCE;
            10'd120: pixels = 8'hC6;
            10'd121: pixels = 8'h66;
            10'd122: pixels = 8'h66;
            10'd123: pixels = 8'h3E;
            10'd124: pixels = 8'h00;
            10'd125: pixels = 8'h00;
            10'd126: pixels = 8'h00;
            10'd127: pixels = 8'h00;
            // 8 : 'H'
            10'd128: pixels = 8'h00;
            10'd129: pixels = 8'h00;
            10'd130: pixels = 8'h00;
            10'd131: pixels = 8'h46;
            10'd132: pixels = 8'h46;
            10'd133: pixels = 8'h46;
            10'd134: pixels = 8'h46;
            10'd135: pixels = 8'h7E;
            10'd136: pixels = 8'h46;
            10'd137: pixels = 8'h46;
            10'd138: pixels = 8'h46;
            10'd139: pixels = 8'h46;
            10'd140: pixels = 8'h00;
            10'd141: pixels = 8'h00;
            10'd142: pixels = 8'h00;
            10'd143: pixels = 8'h00;
            // 9 : 'I'
            10'd144: pixels = 8'h00;
            10'd145: pixels = 8'h00;
            10'd146: pixels = 8'h00;
            10'd147: pixels = 8'h7E;
            10'd148: pixels = 8'h18;
            10'd149: pixels = 8'h18;
            10'd150: pixels = 8'h18;
            10'd151: pixels = 8'h18;
            10'd152: pixels = 8'h18;
            10'd153: pixels = 8'h18;
            10'd154: pixels = 8'h18;
            10'd155: pixels = 8'h7E;
            10'd156: pixels = 8'h00;
            10'd157: pixels = 8'h00;
            10'd158: pixels = 8'h00;
            10'd159: pixels = 8'h00;
            // 10: 'J'
            10'd160: pixels = 8'h00;
            10'd161: pixels = 8'h00;
            10'd162: pixels = 8'h00;
            10'd163: pixels = 8'h7C;
            10'd164: pixels = 8'h0C;
            10'd165: pixels = 8'h0C;
            10'd166: pixels = 8'h0C;
            10'd167: pixels = 8'h0C;
            10'd168: pixels = 8'h0C;
            10'd169: pixels = 8'h0C;
            10'd170: pixels = 8'h4C;
            10'd171: pixels = 8'h38;
            10'd172: pixels = 8'h00;
            10'd173: pixels = 8'h00;
            10'd174: pixels = 8'h00;
            10'd175: pixels = 8'h00;
            // 11: 'K'
            10'd176: pixels = 8'h00;
            10'd177: pixels = 8'h00;
            10'd178: pixels = 8'h00;
            10'd179: pixels = 8'h66;
            10'd180: pixels = 8'h6C;
            10'd181: pixels = 8'h6C;
            10'd182: pixels = 8'h78;
            10'd183: pixels = 8'h78;
            10'd184: pixels = 8'h78;
            10'd185: pixels = 8'h6C;
            10'd186: pixels = 8'h6C;
            10'd187: pixels = 8'h66;
            10'd188: pixels = 8'h00;
            10'd189: pixels = 8'h00;
            10'd190: pixels = 8'h00;
            10'd191: pixels = 8'h00;
            // 12: 'L'
            10'd192: pixels = 8'h00;
            10'd193: pixels = 8'h00;
            10'd194: pixels = 8'h00;
            10'd195: pixels = 8'h60;
            10'd196: pixels = 8'h60;
            10'd197: pixels = 8'h60;
            10'd198: pixels = 8'h60;
            10'd199: pixels = 8'h60;
            10'd200: pixels = 8'h60;
            10'd201: pixels = 8'h60;
            10'd202: pixels = 8'h60;
            10'd203: pixels = 8'h7E;
            10'd204: pixels = 8'h00;
            10'd205: pixels = 8'h00;
            10'd206: pixels = 8'h00;
            10'd207: pixels = 8'h00;
            // 13: 'M'
            10'd208: pixels = 8'h00;
            10'd209: pixels = 8'h00;
            10'd210: pixels = 8'h00;
            10'd211: pixels = 8'h66;
            10'd212: pixels = 8'h6E;
            10'd213: pixels = 8'h6E;
            10'd214: pixels = 8'hFA;
            10'd215: pixels = 8'hDA;
            10'd216: pixels = 8'hDA;
            10'd217: pixels = 8'hC2;
            10'd218: pixels = 8'hC2;
            10'd219: pixels = 8'hC2;
            10'd220: pixels = 8'h00;
            10'd221: pixels = 8'h00;
            10'd222: pixels = 8'h00;
            10'd223: pixels = 8'h00;
            // 14: 'N'
            10'd224: pixels = 8'h00;
            10'd225: pixels = 8'h00;
            10'd226: pixels = 8'h00;
            10'd227: pixels = 8'h66;
            10'd228: pixels = 8'h66;
            10'd229: pixels = 8'h76;
            10'd230: pixels = 8'h76;
            10'd231: pixels = 8'h5E;
            10'd232: pixels = 8'h5E;
            10'd233: pixels = 8'h4E;
            10'd234: pixels = 8'h4E;
            10'd235: pixels = 8'h46;
            10'd236: pixels = 8'h00;
            10'd237: pixels = 8'h00;
            10'd238: pixels = 8'h00;
            10'd239: pixels = 8'h00;
            // 15: 'O'
            10'd240: pixels = 8'h00;
            10'd241: pixels = 8'h00;
            10'd242: pixels = 8'h00;
            10'd243: pixels = 8'h3C;
            10'd244: pixels = 8'h66;
            10'd245: pixels = 8'hC6;
            10'd246: pixels = 8'hC6;
            10'd247: pixels = 8'hC3;
            10'd248: pixels = 8'hC6;
            10'd249: pixels = 8'hC6;
            10'd250: pixels = 8'h66;
            10'd251: pixels = 8'h3C;
            10'd252: pixels = 8'h00;
            10'd253: pixels = 8'h00;
            10'd254: pixels = 8'h00;
            10'd255: pixels = 8'h00;
            // 16: 'P'
            10'd256: pixels = 8'h00;
            10'd257: pixels = 8'h00;
            10'd258: pixels = 8'h00;
            10'd259: pixels = 8'h7C;
            10'd260: pixels = 8'h66;
            10'd261: pixels = 8'h66;
            10'd262: pixels = 8'h66;
            10'd263: pixels = 8'h66;
            10'd264: pixels = 8'h7C;
            10'd265: pixels = 8'h60;
            10'd266: pixels = 8'h60;
            10'd267: pixels = 8'h60;
            10'd268: pixels = 8'h00;
            10'd269: pixels = 8'h00;
            10'd270: pixels = 8'h00;
            10'd271: pixels = 8'h00;
            // 17: 'Q'
            10'd272: pixels = 8'h00;
            10'd273: pixels = 8'h00;
            10'd274: pixels = 8'h00;
            10'd275: pixels = 8'h3C;
            10'd276: pixels = 8'h66;
            10'd277: pixels = 8'hC6;
            10'd278: pixels = 8'hC6;
            10'd279: pixels = 8'hC3;
            10'd280: pixels = 8'hC6;
            10'd281: pixels = 8'hC6;
            10'd282: pixels = 8'h66;
            10'd283: pixels = 8'h3C;
            10'd284: pixels = 8'h18;
            10'd285: pixels = 8'h18;
            10'd286: pixels = 8'h0E;
            10'd287: pixels = 8'h00;
            // 18: 'R'
            10'd288: pixels = 8'h00;
            10'd289: pixels = 8'h00;
            10'd290: pixels = 8'h00;
            10'd291: pixels = 8'h7C;
            10'd292: pixels = 8'h6E;
            10'd293: pixels = 8'h66;
            10'd294: pixels = 8'h6E;
            10'd295: pixels = 8'h7C;
            10'd296: pixels = 8'h6C;
            10'd297: pixels = 8'h6C;
            10'd298: pixels = 8'h66;
            10'd299: pixels = 8'h66;
            10'd300: pixels = 8'h00;
            10'd301: pixels = 8'h00;
            10'd302: pixels = 8'h00;
            10'd303: pixels = 8'h00;
            // 19: 'S'
            10'd304: pixels = 8'h00;
            10'd305: pixels = 8'h00;
            10'd306: pixels = 8'h00;
            10'd307: pixels = 8'h3C;
            10'd308: pixels = 8'h64;
            10'd309: pixels = 8'h60;
            10'd310: pixels = 8'h70;
            10'd311: pixels = 8'h3C;
            10'd312: pixels = 8'h0E;
            10'd313: pixels = 8'h06;
            10'd314: pixels = 8'h46;
            10'd315: pixels = 8'h7C;
            10'd316: pixels = 8'h00;
            10'd317: pixels = 8'h00;
            10'd318: pixels = 8'h00;
            10'd319: pixels = 8'h00;
            // 20: 'T'
            10'd320: pixels = 8'h00;
            10'd321: pixels = 8'h00;
            10'd322: pixels = 8'h00;
            10'd323: pixels = 8'hFE;
            10'd324: pixels = 8'h18;
            10'd325: pixels = 8'h18;
            10'd326: pixels = 8'h18;
            10'd327: pixels = 8'h18;
            10'd328: pixels = 8'h18;
            10'd329: pixels = 8'h18;
            10'd330: pixels = 8'h18;
            10'd331: pixels = 8'h18;
            10'd332: pixels = 8'h00;
            10'd333: pixels = 8'h00;
            10'd334: pixels = 8'h00;
            10'd335: pixels = 8'h00;
            // 21: 'U'
            10'd336: pixels = 8'h00;
            10'd337: pixels = 8'h00;
            10'd338: pixels = 8'h00;
            10'd339: pixels = 8'hC6;
            10'd340: pixels = 8'hC6;
            10'd341: pixels = 8'hC6;
            10'd342: pixels = 8'hC6;
            10'd343: pixels = 8'hC6;
            10'd344: pixels = 8'hC6;
            10'd345: pixels = 8'h46;
            10'd346: pixels = 8'h66;
            10'd347: pixels = 8'h3C;
            10'd348: pixels = 8'h00;
            10'd349: pixels = 8'h00;
            10'd350: pixels = 8'h00;
            10'd351: pixels = 8'h00;
            // 22: 'V'
            10'd352: pixels = 8'h00;
            10'd353: pixels = 8'h00;
            10'd354: pixels = 8'h00;
            10'd355: pixels = 8'hC3;
            10'd356: pixels = 8'hC6;
            10'd357: pixels = 8'h66;
            10'd358: pixels = 8'h66;
            10'd359: pixels = 8'h64;
            10'd360: pixels = 8'h3C;
            10'd361: pixels = 8'h3C;
            10'd362: pixels = 8'h3C;
            10'd363: pixels = 8'h38;
            10'd364: pixels = 8'h00;
            10'd365: pixels = 8'h00;
            10'd366: pixels = 8'h00;
            10'd367: pixels = 8'h00;
            // 23: 'W'
            10'd368: pixels = 8'h00;
            10'd369: pixels = 8'h00;
            10'd370: pixels = 8'h00;
            10'd371: pixels = 8'hC3;
            10'd372: pixels = 8'hC3;
            10'd373: pixels = 8'hC2;
            10'd374: pixels = 8'hDA;
            10'd375: pixels = 8'hDA;
            10'd376: pixels = 8'hDA;
            10'd377: pixels = 8'hEE;
            10'd378: pixels = 8'h6E;
            10'd379: pixels = 8'h66;
            10'd380: pixels = 8'h00;
            10'd381: pixels = 8'h00;
            10'd382: pixels = 8'h00;
            10'd383: pixels = 8'h00;
            // 24: 'X'
            10'd384: pixels = 8'h00;
            10'd385: pixels = 8'h00;
            10'd386: pixels = 8'h00;
            10'd387: pixels = 8'hE6;
            10'd388: pixels = 8'h6E;
            10'd389: pixels = 8'h3C;
            10'd390: pixels = 8'h38;
            10'd391: pixels = 8'h18;
            10'd392: pixels = 8'h3C;
            10'd393: pixels = 8'h6C;
            10'd394: pixels = 8'h66;
            10'd395: pixels = 8'hC6;
            10'd396: pixels = 8'h00;
            10'd397: pixels = 8'h00;
            10'd398: pixels = 8'h00;
            10'd399: pixels = 8'h00;
            // 25: 'Y'
            10'd400: pixels = 8'h00;
            10'd401: pixels = 8'h00;
            10'd402: pixels = 8'h00;
            10'd403: pixels = 8'hC6;
            10'd404: pixels = 8'h66;
            10'd405: pixels = 8'h6C;
            10'd406: pixels = 8'h3C;
            10'd407: pixels = 8'h38;
            10'd408: pixels = 8'h18;
            10'd409: pixels = 8'h18;
            10'd410: pixels = 8'h18;
            10'd411: pixels = 8'h18;
            10'd412: pixels = 8'h00;
            10'd413: pixels = 8'h00;
            10'd414: pixels = 8'h00;
            10'd415: pixels = 8'h00;
            // 26: 'Z'
            10'd416: pixels = 8'h00;
            10'd417: pixels = 8'h00;
            10'd418: pixels = 8'h00;
            10'd419: pixels = 8'h7E;
            10'd420: pixels = 8'h0C;
            10'd421: pixels = 8'h0C;
            10'd422: pixels = 8'h18;
            10'd423: pixels = 8'h18;
            10'd424: pixels = 8'h30;
            10'd425: pixels = 8'h30;
            10'd426: pixels = 8'h60;
            10'd427: pixels = 8'h7E;
            10'd428: pixels = 8'h00;
            10'd429: pixels = 8'h00;
            10'd430: pixels = 8'h00;
            10'd431: pixels = 8'h00;
            // 32: 'space'
            10'd512: pixels = 8'h00;
            10'd513: pixels = 8'h00;
            10'd514: pixels = 8'h00;
            10'd515: pixels = 8'h00;
            10'd516: pixels = 8'h00;
            10'd517: pixels = 8'h00;
            10'd518: pixels = 8'h00;
            10'd519: pixels = 8'h00;
            10'd520: pixels = 8'h00;
            10'd521: pixels = 8'h00;
            10'd522: pixels = 8'h00;
            10'd523: pixels = 8'h00;
            10'd524: pixels = 8'h00;
            10'd525: pixels = 8'h00;
            10'd526: pixels = 8'h00;
            10'd527: pixels = 8'h00;
            // 45: '-'
            10'd720: pixels = 8'h00;
            10'd721: pixels = 8'h00;
            10'd722: pixels = 8'h00;
            10'd723: pixels = 8'h00;
            10'd724: pixels = 8'h00;
            10'd725: pixels = 8'h00;
            10'd726: pixels = 8'h00;
            10'd727: pixels = 8'h00;
            10'd728: pixels = 8'h3C;
            10'd729: pixels = 8'h00;
            10'd730: pixels = 8'h00;
            10'd731: pixels = 8'h00;
            10'd732: pixels = 8'h00;
            10'd733: pixels = 8'h00;
            10'd734: pixels = 8'h00;
            10'd735: pixels = 8'h00;
            // 46: '.'
            10'd736: pixels = 8'h00;
            10'd737: pixels = 8'h00;
            10'd738: pixels = 8'h00;
            10'd739: pixels = 8'h00;
            10'd740: pixels = 8'h00;
            10'd741: pixels = 8'h00;
            10'd742: pixels = 8'h00;
            10'd743: pixels = 8'h00;
            10'd744: pixels = 8'h00;
            10'd745: pixels = 8'h18;
            10'd746: pixels = 8'h38;
            10'd747: pixels = 8'h18;
            10'd748: pixels = 8'h00;
            10'd749: pixels = 8'h00;
            10'd750: pixels = 8'h00;
            10'd751: pixels = 8'h00;
            // 47: '/'
            10'd752: pixels = 8'h00;
            10'd753: pixels = 8'h00;
            10'd754: pixels = 8'h06;
            10'd755: pixels = 8'h04;
            10'd756: pixels = 8'h0C;
            10'd757: pixels = 8'h08;
            10'd758: pixels = 8'h18;
            10'd759: pixels = 8'h18;
            10'd760: pixels = 8'h30;
            10'd761: pixels = 8'h30;
            10'd762: pixels = 8'h60;
            10'd763: pixels = 8'h60;
            10'd764: pixels = 8'h40;
            10'd765: pixels = 8'h00;
            10'd766: pixels = 8'h00;
            10'd767: pixels = 8'h00;
            // 48: '0'
            10'd768: pixels = 8'h00;
            10'd769: pixels = 8'h00;
            10'd770: pixels = 8'h00;
            10'd771: pixels = 8'h3C;
            10'd772: pixels = 8'h66;
            10'd773: pixels = 8'h46;
            10'd774: pixels = 8'hCE;
            10'd775: pixels = 8'hDE;
            10'd776: pixels = 8'hE6;
            10'd777: pixels = 8'h66;
            10'd778: pixels = 8'h66;
            10'd779: pixels = 8'h3C;
            10'd780: pixels = 8'h00;
            10'd781: pixels = 8'h00;
            10'd782: pixels = 8'h00;
            10'd783: pixels = 8'h00;
            // 49: '1'
            10'd784: pixels = 8'h00;
            10'd785: pixels = 8'h00;
            10'd786: pixels = 8'h00;
            10'd787: pixels = 8'h18;
            10'd788: pixels = 8'h78;
            10'd789: pixels = 8'h58;
            10'd790: pixels = 8'h18;
            10'd791: pixels = 8'h18;
            10'd792: pixels = 8'h18;
            10'd793: pixels = 8'h18;
            10'd794: pixels = 8'h18;
            10'd795: pixels = 8'h7E;
            10'd796: pixels = 8'h00;
            10'd797: pixels = 8'h00;
            10'd798: pixels = 8'h00;
            10'd799: pixels = 8'h00;
            // 50: '2'
            10'd800: pixels = 8'h00;
            10'd801: pixels = 8'h00;
            10'd802: pixels = 8'h00;
            10'd803: pixels = 8'h3C;
            10'd804: pixels = 8'h4C;
            10'd805: pixels = 8'h06;
            10'd806: pixels = 8'h06;
            10'd807: pixels = 8'h0C;
            10'd808: pixels = 8'h18;
            10'd809: pixels = 8'h30;
            10'd810: pixels = 8'h70;
            10'd811: pixels = 8'h7E;
            10'd812: pixels = 8'h00;
            10'd813: pixels = 8'h00;
            10'd814: pixels = 8'h00;
            10'd815: pixels = 8'h00;
            // 51: '3'
            10'd816: pixels = 8'h00;
            10'd817: pixels = 8'h00;
            10'd818: pixels = 8'h00;
            10'd819: pixels = 8'h7C;
            10'd820: pixels = 8'h0C;
            10'd821: pixels = 8'h06;
            10'd822: pixels = 8'h0C;
            10'd823: pixels = 8'h3C;
            10'd824: pixels = 8'h06;
            10'd825: pixels = 8'h06;
            10'd826: pixels = 8'h0E;
            10'd827: pixels = 8'h7C;
            10'd828: pixels = 8'h00;
            10'd829: pixels = 8'h00;
            10'd830: pixels = 8'h00;
            10'd831: pixels = 8'h00;
            // 52: '4'
            10'd832: pixels = 8'h00;
            10'd833: pixels = 8'h00;
            10'd834: pixels = 8'h00;
            10'd835: pixels = 8'h1C;
            10'd836: pixels = 8'h1C;
            10'd837: pixels = 8'h3C;
            10'd838: pixels = 8'h2C;
            10'd839: pixels = 8'h6C;
            10'd840: pixels = 8'hCC;
            10'd841: pixels = 8'hFF;
            10'd842: pixels = 8'h0C;
            10'd843: pixels = 8'h0C;
            10'd844: pixels = 8'h00;
            10'd845: pixels = 8'h00;
            10'd846: pixels = 8'h00;
            10'd847: pixels = 8'h00;
            // 53: '5'
            10'd848: pixels = 8'h00;
            10'd849: pixels = 8'h00;
            10'd850: pixels = 8'h00;
            10'd851: pixels = 8'h7E;
            10'd852: pixels = 8'h60;
            10'd853: pixels = 8'h60;
            10'd854: pixels = 8'h7C;
            10'd855: pixels = 8'h0E;
            10'd856: pixels = 8'h06;
            10'd857: pixels = 8'h06;
            10'd858: pixels = 8'h0C;
            10'd859: pixels = 8'h78;
            10'd860: pixels = 8'h00;
            10'd861: pixels = 8'h00;
            10'd862: pixels = 8'h00;
            10'd863: pixels = 8'h00;
            // 54: '6'
            10'd864: pixels = 8'h00;
            10'd865: pixels = 8'h00;
            10'd866: pixels = 8'h00;
            10'd867: pixels = 8'h1E;
            10'd868: pixels = 8'h30;
            10'd869: pixels = 8'h60;
            10'd870: pixels = 8'h7C;
            10'd871: pixels = 8'h66;
            10'd872: pixels = 8'h66;
            10'd873: pixels = 8'h66;
            10'd874: pixels = 8'h66;
            10'd875: pixels = 8'h3C;
            10'd876: pixels = 8'h00;
            10'd877: pixels = 8'h00;
            10'd878: pixels = 8'h00;
            10'd879: pixels = 8'h00;
            // 55: '7'
            10'd880: pixels = 8'h00;
            10'd881: pixels = 8'h00;
            10'd882: pixels = 8'h00;
            10'd883: pixels = 8'h7E;
            10'd884: pixels = 8'h06;
            10'd885: pixels = 8'h0C;
            10'd886: pixels = 8'h0C;
            10'd887: pixels = 8'h18;
            10'd888: pixels = 8'h18;
            10'd889: pixels = 8'h38;
            10'd890: pixels = 8'h30;
            10'd891: pixels = 8'h30;
            10'd892: pixels = 8'h00;
            10'd893: pixels = 8'h00;
            10'd894: pixels = 8'h00;
            10'd895: pixels = 8'h00;
            // 56: '8'
            10'd896: pixels = 8'h00;
            10'd897: pixels = 8'h00;
            10'd898: pixels = 8'h00;
            10'd899: pixels = 8'h3C;
            10'd900: pixels = 8'h66;
            10'd901: pixels = 8'h66;
            10'd902: pixels = 8'h7C;
            10'd903: pixels = 8'h3C;
            10'd904: pixels = 8'h6E;
            10'd905: pixels = 8'h66;
            10'd906: pixels = 8'h66;
            10'd907: pixels = 8'h3C;
            10'd908: pixels = 8'h00;
            10'd909: pixels = 8'h00;
            10'd910: pixels = 8'h00;
            10'd911: pixels = 8'h00;
            // 57: '9'
            10'd912: pixels = 8'h00;
            10'd913: pixels = 8'h00;
            10'd914: pixels = 8'h00;
            10'd915: pixels = 8'h3C;
            10'd916: pixels = 8'h6E;
            10'd917: pixels = 8'h46;
            10'd918: pixels = 8'hC6;
            10'd919: pixels = 8'h66;
            10'd920: pixels = 8'h7E;
            10'd921: pixels = 8'h06;
            10'd922: pixels = 8'h0C;
            10'd923: pixels = 8'h78;
            10'd924: pixels = 8'h00;
            10'd925: pixels = 8'h00;
            10'd926: pixels = 8'h00;
            10'd927: pixels = 8'h00;
            // 58: ':'
            10'd928: pixels = 8'h00;
            10'd929: pixels = 8'h00;
            10'd930: pixels = 8'h00;
            10'd931: pixels = 8'h00;
            10'd932: pixels = 8'h00;
            10'd933: pixels = 8'h18;
            10'd934: pixels = 8'h18;
            10'd935: pixels = 8'h00;
            10'd936: pixels = 8'h00;
            10'd937: pixels = 8'h00;
            10'd938: pixels = 8'h18;
            10'd939: pixels = 8'h18;
            10'd940: pixels = 8'h00;
            10'd941: pixels = 8'h00;
            10'd942: pixels = 8'h00;
            10'd943: pixels = 8'h00;
            default: pixels = 8'h00;
        endcase
    end

endmodule
